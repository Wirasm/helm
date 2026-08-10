import Foundation

/// What a Claude Code session says it is doing, collapsed to the one axis the
/// board renders.
///
/// The registry publishes four values; the board asks one question — is this agent
/// carrying on without you, or is it not. `waiting` (blocked on a prompt) and
/// `idle` (finished) are the same state seen twice: both mean it is your turn.
/// An unrecognised value is deliberately not mapped to either — see `AgentSession`.
enum AgentStatus: String, Decodable, Equatable {
    case busy, shell, idle, waiting

    var isWorking: Bool {
        switch self {
        case .busy, .shell: true
        case .idle, .waiting: false
        }
    }
}

/// One row of Claude Code's live session registry, `~/.claude/sessions/<pid>.json`.
///
/// Only the fields the board uses are decoded. `status` is optional and decoded
/// permissively on purpose: a file written mid-transition, or by a newer Claude
/// Code carrying a status this build has never heard of, must render *nothing*
/// rather than default to idle and light a workspace that is fine.
struct AgentSession: Equatable {
    let pid: pid_t
    /// The agent's working directory. Not the attribution — the pid is (see
    /// `BoardModel.presence`). Decoded because it is the only field that could
    /// ever explain a surprising mark while debugging.
    let cwd: String?
    let status: AgentStatus?
    /// Claude Code's own id for the conversation. The board does not use it; the
    /// chat face does, because `sessionId` + `cwd` are what locate the transcript
    /// on disk (`TranscriptLocator`).
    ///
    /// It lives here rather than in a second reader by #28's ruling — one registry
    /// row type, split only if the two consumers genuinely diverge. `var` with a
    /// default so the memberwise initializer stays source-compatible for callers
    /// that only care about the board's three fields.
    var sessionId: String? = nil
    /// What the agent says it is waiting **for**, in Claude Code's own words — `"permission
    /// prompt"`, `"input needed"`, `"dialog open"`, `"sandbox request"`, … Absent unless
    /// `status` is `waiting`.
    ///
    /// **This is the field #283 turns on, and it is why `status` alone was not enough.** The
    /// board collapses `waiting` and `idle` into one answer on purpose — see `AgentStatus` —
    /// because both mean *it is your turn*. For a coordinator reading `snapshot.json` they are
    /// opposites: `idle` is an agent that finished, `waiting` on a **permission prompt** is an
    /// agent that cannot finish and that nobody is going to answer, because the spool's whole
    /// premise is that nobody is at the pane.
    ///
    /// A bare `String` rather than an enum, for `BenchSnapshot.ResumableRecord.blockedReason`'s
    /// reason: this is a free-form label Claude Code composes, and a reason this build has never
    /// heard of is something a reader can still print.
    var waitingFor: String? = nil
    /// When `status` last **changed** — not a heartbeat, and `BoardModel` says so in as many
    /// words. Claude Code stamps it only on a status transition, which is exactly what makes it
    /// the useful thing to publish: *waiting since T* survives a snapshot that is never rewritten,
    /// where *waiting for N seconds* would go stale the moment it was written down.
    ///
    /// Claude Code writes epoch **milliseconds**; this is the `Date` they name.
    var statusUpdatedAt: Date? = nil
}

extension AgentSession: Decodable {
    private enum CodingKeys: String, CodingKey {
        case pid, cwd, status, sessionId, waitingFor, statusUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(pid_t.self, forKey: .pid)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        waitingFor = try container.decodeIfPresent(String.self, forKey: .waitingFor)
        // Milliseconds, and a non-finite one is dropped rather than turned into a `Date` no
        // arithmetic can survive — Claude Code's own reader range-checks this field too.
        statusUpdatedAt =
            try container.decodeIfPresent(Double.self, forKey: .statusUpdatedAt)
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        // Unknown and absent collapse to the same nil. Synthesised `Decodable`
        // would instead throw on an unknown value and drop the whole row — the
        // same outcome by accident rather than by rule, and it would take a
        // sibling field down with it.
        status = try container.decodeIfPresent(String.self, forKey: .status)
            .flatMap(AgentStatus.init(rawValue:))
    }
}

/// Reads Claude Code's session registry. The filesystem IS the API — no hooks,
/// no screen-scrape, nothing helm has to launch.
///
/// Claude Code only, by rule. pi publishes no registry, so a pi terminal has no
/// row here and reads as unmarked — absence, not a false idle.
enum AgentRegistry {
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
    }

    /// Every readable row under `root`. A missing directory, an unreadable file or
    /// a malformed one yields absence, never an error: the board is a hint, and a
    /// hint that throws is worse than a hint that is briefly empty. One bad file
    /// costs its own row and nothing else.
    static func sessions(in root: URL) -> [AgentSession] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }

        let decoder = JSONDecoder()
        return entries.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url)
            else { return nil }
            return try? decoder.decode(AgentSession.self, from: data)
        }
    }

    /// The `sessionFor:` `AddressBook` asks for: which Claude session is running in a pid.
    ///
    /// **One read of the registry, then a pure closure over it.** Both callers ask about
    /// several pids for one answer — `BenchSnapshotModel` about every terminal pane it is
    /// projecting, `SpoolModel` about one pane per poll attempt — and re-listing the directory
    /// per pid would turn a two-second snapshot into a directory scan per pane.
    ///
    /// The consequence is that the answer is **as fresh as the call**, which is why `SpoolModel`
    /// builds a new lookup on every poll attempt: the row it is waiting for is written by an
    /// agent that has not started yet, and a lookup captured before the poll would never see it.
    ///
    /// `nil` for a pid with no row — silence, which `AddressBook` is careful never to read as
    /// an answer. `AgentLocator` is deliberately not involved: this is the registry's own
    /// "which session is in THIS process", one row per pid, and the wrapper case is handled by
    /// `AddressBook`'s ancestry branch rather than by widening this question.
    ///
    /// # It runs pid → session, and that is why it needs no liveness check
    ///
    /// Worth stating, because the JS half of #247 asks the same registry the **opposite** way
    /// and does need one. `sessionPid(sessionId)` in `hooks/helm-mail.mjs` scans *by session id*
    /// and hands back a pid it discovered from file contents — a number that can name a dead
    /// process, hence its `pidAlive(row.pid)` filter. This runs the other direction: the caller
    /// supplies the pid, which is a pane's live foreground process read off the pty, and
    /// `$0.pid == pid` means any row that matches carries that same live number. A liveness
    /// guard here would be asking whether a pid we just watched running is running. The JS
    /// analogue of *this* direction is `ownerGone`'s `<pid>.json` read, which is likewise
    /// unguarded, for the same reason.
    ///
    /// The residual is a row Claude Code left behind for a pid the OS then recycled. **Measured
    /// 2026-08-06: it cleans up after itself** — a real agent spawned through the spool at pid
    /// 37255 had its row removed the moment the process exited. So this needs a crash or a
    /// `SIGKILL` to arise, it is symmetric with what both JS reapers already live with, and it
    /// is not new exposure: the pre-#247 join reached the very same wrong mailbox by the very
    /// same pid, with no registry involved at all.
    static func sessionLookup(in root: URL = defaultRoot) -> (pid_t) -> String? {
        sessionLookup(over: rows(in: root))
    }

    /// The same closure over rows a caller already read.
    ///
    /// **It exists so that reading the registry once and reading it twice cannot disagree
    /// (#283).** `BenchSnapshotModel` needs the whole row per pane now — the agent's own
    /// `status`/`waitingFor` go into `snapshot.json` — as well as this pid→session lookup, and
    /// calling `sessionLookup(in:)` beside `rows(in:)` would list the same directory twice per
    /// publish and let one publish's `owner` join disagree with the same publish's `agent`
    /// record. That is `row(in:)`'s defect exactly, one level up, and this is `row(in:)`'s answer
    /// to it: the rule is a function over rows the caller holds.
    static func sessionLookup(over rows: [pid_t: AgentSession]) -> (pid_t) -> String? {
        { pid in rows[pid]?.sessionId }
    }

    /// The same read, keyed by pid, for the caller that needs the whole row rather than the
    /// session id — `AgentObserver`, which also wants `cwd` (#63).
    ///
    /// **It exists so there is exactly one rule for a duplicate pid.** This was two functions:
    /// `sessionLookup` did `rows.first { $0.pid == pid }` and a second dictionary elsewhere did
    /// `uniquingKeysWith: { _, last in last }` — the same directory read twice, both authors
    /// reasoning in prose about the identical degenerate case and reaching **opposite**
    /// conclusions. Nothing detected the disagreement, and its cost was `snapshot.json`
    /// attributing one session to a pane while the pane's own persisted record named another.
    /// Caught in review before it shipped, and the shape of the defect is `AGENTS.md`'s own:
    /// one rule, two spellings, nothing to notice when they diverge.
    ///
    /// **The rule is last-wins, and it is arbitrary on purpose.** Claude Code names the file
    /// after the pid, so two rows for one pid means two files claiming the same process — they
    /// cannot both be true and neither is more credible. What matters is not which is picked
    /// but that every reader picks the same one, which is why this is a function and not a
    /// convention. `Dictionary(_:uniquingKeysWith:)` rather than `uniqueKeysWithValues:`,
    /// because the latter traps and a hand-edited registry directory is not worth a crash.
    static func rows(in root: URL = defaultRoot) -> [pid_t: AgentSession] {
        row(in: sessions(in: root))
    }

    /// The same keying over rows a caller already has.
    ///
    /// **It exists because "every reader" turned out to be narrower than it sounded.** The
    /// first version of this rule unified two readers and left two more — `AgentLocator
    /// .session(in:forPid:)` and `ChatModel`'s half-second refresh, both doing their own
    /// `first(where: { $0.pid == pid })` over the raw array. They are the *chat face's* answer
    /// to "which session is in this pane", so a divergence there is not academic: the face
    /// renders one conversation's transcript while `WorkbenchModel` records another as the
    /// pane's `ResumableAgent` and `snapshot.json` reports a third, each internally consistent
    /// and none of them erroring.
    ///
    /// Pure and array-in, because those two callers hold rows rather than a root — `AgentLocator`
    /// takes the registry as an argument precisely so its rule is testable without a filesystem,
    /// and making it read a directory instead would trade one seam for a worse one.
    static func row(in rows: [AgentSession]) -> [pid_t: AgentSession] {
        Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The one row for a pid, out of rows a caller already has. The direct-match step every
    /// reader shares; see `row(in:)` for why it is a function.
    static func row(for pid: pid_t, in rows: [AgentSession]) -> AgentSession? {
        row(in: rows)[pid]
    }
}
