import Foundation

/// The two session verbs the sessions drawer sends benchd (#384): `sessions/all` (every agent
/// session in a workspace) and `sessions/dismiss` (take a finished one off the list). Their
/// args and the reply are pinned by `daemon/fixtures/session-rows.json`, which the daemon gate
/// holds to `bench_wire::sessions`.
package enum BenchSessionsRequest: Encodable, Equatable, Sendable {
    case all(id: String, workspace: String)
    case dismiss(id: String, harness: String, session: String)

    private enum CodingKeys: String, CodingKey { case id, verb, args }
    private enum ArgKeys: String, CodingKey { case workspace, harness, id }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var args = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        switch self {
        case let .all(id, workspace):
            try c.encode(id, forKey: .id)
            try c.encode("sessions/all", forKey: .verb)
            try args.encode(workspace, forKey: .workspace)
        case let .dismiss(id, harness, session):
            try c.encode(id, forKey: .id)
            try c.encode("sessions/dismiss", forKey: .verb)
            try args.encode(harness, forKey: .harness)
            try args.encode(session, forKey: .id)
        }
    }
}

/// `sessions/all`'s answer, reduced to what the drawer shows. Running rows first, then newest
/// first — benchd's order, which the drawer keeps.
package struct BenchSessionList: Decodable, Equatable, Sendable {
    package var rows: [BenchSessionRow]
    /// Files benchd could not read as a shape it knows; each skipped a row.
    package var unreadable: [Unreadable]

    package struct Unreadable: Decodable, Equatable, Sendable {
        package var source: String
        package var path: String
        package var why: String
    }

    private enum CodingKeys: String, CodingKey { case rows, unreadable }

    package init(rows: [BenchSessionRow], unreadable: [Unreadable] = []) {
        self.rows = rows
        self.unreadable = unreadable
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = try c.decode([BenchSessionRow].self, forKey: .rows)
        unreadable = try c.decodeIfPresent([Unreadable].self, forKey: .unreadable) ?? []
    }
}

/// One session (`bench_wire::SessionRow`). `open` is benchd's decision, computed in one place;
/// the drawer only carries it out.
package struct BenchSessionRow: Decodable, Equatable, Sendable, Identifiable {
    /// `claude`, `codex` or `pi`, as benchd spells it; sent back as is to dismiss.
    package var harness: String
    package var id: String
    /// Set only for a subagent: the session that started it.
    package var parent: String?
    package var name: String?
    package var cwd: String
    package var state: State
    package var open: Open
    package var updatedAtMs: UInt64

    package enum State: Equatable, Sendable {
        /// `activity` is the harness's own word: busy, shell, idle, waiting, blocked,
        /// waiting_on_tasks, unknown. `detail` is what it is waiting for, when it says.
        case running(activity: String, detail: String?)
        case finished(atMs: UInt64)
    }

    package enum Open: Equatable, Sendable {
        case focusPane(UUID)
        case benchAttach(session: String)
        case claudeAttach(job: String)
        /// Start `argv` in a new pane at `cwd`.
        case resume(argv: [String], cwd: String)
        /// Read-only: the subagent's transcript.
        case transcript(path: String, parent: String)
    }

    private enum CodingKeys: String, CodingKey {
        case harness, id, parent, name, cwd, state, open
        case updatedAtMs = "updated_at_ms"
    }

    package init(
        harness: String, id: String, parent: String? = nil, name: String? = nil, cwd: String,
        state: State, open: Open, updatedAtMs: UInt64
    ) {
        self.harness = harness
        self.id = id
        self.parent = parent
        self.name = name
        self.cwd = cwd
        self.state = state
        self.open = open
        self.updatedAtMs = updatedAtMs
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        harness = try c.decode(String.self, forKey: .harness)
        id = try c.decode(String.self, forKey: .id)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        cwd = try c.decode(String.self, forKey: .cwd)
        state = try c.decode(State.self, forKey: .state)
        open = try c.decode(Open.self, forKey: .open)
        updatedAtMs = try c.decode(UInt64.self, forKey: .updatedAtMs)
    }
}

extension BenchSessionRow.State: Decodable {
    private enum CodingKeys: String, CodingKey { case kind, activity, atMs = "at_ms" }
    private enum ActivityKeys: String, CodingKey {
        case kind, waitingFor = "waiting_for", state, detail, count
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "finished":
            self = .finished(atMs: try c.decode(UInt64.self, forKey: .atMs))
        case "running":
            let a = try c.nestedContainer(keyedBy: ActivityKeys.self, forKey: .activity)
            let kind = try a.decode(String.self, forKey: .kind)
            let detail: String? =
                switch kind {
                case "waiting": try a.decodeIfPresent(String.self, forKey: .waitingFor)
                case "blocked":
                    try a.decodeIfPresent(String.self, forKey: .detail)
                        ?? a.decodeIfPresent(String.self, forKey: .state)
                case "waiting_on_tasks":
                    try a.decodeIfPresent(Int.self, forKey: .count).map { "\($0) tasks" }
                default: nil
                }
            self = .running(activity: kind, detail: detail)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "a session state helm does not know: \(other)")
        }
    }
}

extension BenchSessionRow.Open: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, pane, session, job, argv, cwd, path, parent
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "focus_pane": self = .focusPane(try c.decode(UUID.self, forKey: .pane))
        case "bench_attach":
            self = .benchAttach(session: try c.decode(String.self, forKey: .session))
        case "claude_attach": self = .claudeAttach(job: try c.decode(String.self, forKey: .job))
        case "resume":
            self = .resume(
                argv: try c.decode([String].self, forKey: .argv),
                cwd: try c.decode(String.self, forKey: .cwd))
        case "transcript":
            self = .transcript(
                path: try c.decode(String.self, forKey: .path),
                parent: try c.decode(String.self, forKey: .parent))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "an open action helm does not know: \(other)")
        }
    }
}
