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
}

extension AgentSession: Decodable {
    private enum CodingKeys: String, CodingKey { case pid, cwd, status, sessionId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(pid_t.self, forKey: .pid)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
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
        let rows = sessions(in: root)
        return { pid in rows.first { $0.pid == pid }?.sessionId }
    }
}
