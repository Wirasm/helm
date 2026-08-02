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
}
