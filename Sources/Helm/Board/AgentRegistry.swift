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
    /// resume record (#63) and the spool's owner join do, and `sessionId` + `cwd` are
    /// what locate the transcript on disk (`TranscriptLocator`).
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
    /// When `status` **or `waitingFor`** last changed — a transition time, not a heartbeat.
    ///
    /// **Both halves of that sentence are load-bearing, and the second one is easy to get wrong.**
    /// The writer stamps this whenever the payload carries a `status` at all —
    /// `{...e, updatedAt: r, ...e.status !== undefined && { statusUpdatedAt: r }}` — and the
    /// interactive caller's effect fires on `[status, waitingFor]`, so a change to *what* it is
    /// blocked on moves this even when it stays `waiting`. That is **better** for the use here
    /// rather than a caveat: #283 asks *waiting for **this** since T*, so a prompt replaced by a
    /// different prompt should restart the age, and it does.
    ///
    /// **Not a heartbeat, measured rather than assumed.** The discriminating case is a forced
    /// **non-status** write: a `/rename` moved `updatedAt` by 9 ms and left this field alone.
    /// Corroborated three more ways — twelve minutes of a continuously working session produced
    /// zero writes to it, a captured `idle → busy → idle` moved it exactly at each transition, and
    /// all eight call sites in the shipped 2.1.226 source were enumerated with none of them
    /// periodic. So `now - statusUpdatedAt` really is an age, which is what
    /// `BenchSnapshot.AgentRecord.statusUpdatedAt` spends.
    ///
    /// **The one theoretical way it resets without the agent moving**, recorded because it belongs
    /// beside the claim rather than being discovered later: a REPL remount would re-run that
    /// effect and rewrite an unchanged status. Not observed, and nothing remounts periodically.
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

    /// The registry keyed by pid, for the callers that need a pane's agent: `AgentObserver`,
    /// which wants `cwd` (#63), and `BenchSnapshotModel`, which publishes its status (#283).
    ///
    /// **It exists so there is exactly one rule for a duplicate pid**: two readers that built
    /// their own dictionaries once reached opposite answers for it, and `snapshot.json` named a
    /// different session from the one the pane's own record held.
    ///
    /// **The rule is last-wins, and it is arbitrary on purpose.** Claude Code names the file
    /// after the pid, so two rows for one pid means two files claiming the same process — they
    /// cannot both be true and neither is more credible. What matters is not which is picked
    /// but that every reader picks the same one, which is why this is a function and not a
    /// convention. `Dictionary(_:uniquingKeysWith:)` rather than `uniqueKeysWithValues:`,
    /// because the latter traps and a hand-edited registry directory is not worth a crash.
    static func rows(in root: URL = defaultRoot) -> [pid_t: AgentSession] {
        Dictionary(sessions(in: root).map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
    }
}
