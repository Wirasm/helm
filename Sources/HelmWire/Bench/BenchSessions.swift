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
    /// The short branch checked out in this row's worktree, when it has a readable branch.
    package var branch: String?
    /// The model the agent runs, as its harness last recorded it; nil until it records one.
    package var model: String?
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
        /// A finished conversation, resumed at `cwd`. helm resumes it through benchd's
        /// `spawn --resume`, which sends the resume notice and brings back a removed worktree
        /// (#621); `argv` is the harness's own command, for a reader of `bench sessions --all`.
        case resume(argv: [String], cwd: String)
        /// Read-only: the subagent's transcript.
        case transcript(path: String, parent: String)
    }

    private enum CodingKeys: String, CodingKey {
        case harness, id, parent, name, branch, model, cwd, state, open
        case updatedAtMs = "updated_at_ms"
    }

    package init(
        harness: String, id: String, parent: String? = nil, name: String? = nil,
        branch: String? = nil, model: String? = nil, cwd: String,
        state: State, open: Open, updatedAtMs: UInt64
    ) {
        self.harness = harness
        self.id = id
        self.parent = parent
        self.name = name
        self.branch = branch
        self.model = model
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
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        model = try c.decodeIfPresent(String.self, forKey: .model)
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

/// `sessions`: every session benchd runs (M5b). helm asks for the pane each one is shown in, what
/// has its terminal, and what the agent there reports: the operator's shells run in benchd now,
/// so a pane's own pty holds `bench attach`, not the agent. The answer is pinned by
/// `daemon/fixtures/session-list.json`, which the daemon gate holds to `bench_wire::LiveSessions`.
package struct BenchLiveSessionsRequest: Encodable, Equatable, Sendable {
    package var id: String
    package var verb = "sessions"

    package init(id: String) { self.id = id }
}

/// `sessions`' answer, reduced to what helm reads.
package struct BenchLiveSessions: Decodable, Equatable, Sendable {
    package var sessions: [Entry]
    /// Each harness's plan limits as benchd last heard them (#143); empty when none has reported.
    package var usage: [BenchUsage]

    private enum CodingKeys: String, CodingKey { case sessions, usage }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decode([Entry].self, forKey: .sessions)
        usage = try c.decodeIfPresent([BenchUsage].self, forKey: .usage) ?? []
    }

    package struct Entry: Decodable, Equatable, Sendable {
        package var session: String
        /// The pane showing it, if one does.
        package var pane: UUID?
        /// What has the terminal: the session's own process, or the job its shell runs. nil once
        /// the session has ended.
        package var foregroundPid: Int32?
        /// The agent in it is waiting on the operator (M1, #357); nil when it is not.
        package var waiting: Waiting?
        /// What the agent in it says it is doing (M5c); nil when nothing there reports.
        package var report: Report?

        private enum CodingKeys: String, CodingKey {
            case session, pane, waiting, report
            case foregroundPid = "foreground_pid"
        }

        package init(
            session: String, pane: UUID?, foregroundPid: Int32?, waiting: Waiting? = nil,
            report: Report? = nil
        ) {
            self.session = session
            self.pane = pane
            self.foregroundPid = foregroundPid
            self.waiting = waiting
            self.report = report
        }
    }

    /// `bench_wire::AgentReport`: what an agent says it is doing, read on benchd's machine —
    /// Claude Code's registry row for the session's foreground process, else the agent's last
    /// hook. So helm reads no registry of its own, and a benchd on another machine still lights
    /// presence (M5c, #459).
    package struct Report: Decodable, Equatable, Sendable {
        /// The harness's own word (`bench_wire::Activity`'s `kind`): `busy`, `shell`, `idle` or
        /// `waiting`, the only four a registry row or a hook says.
        package var activity: String
        /// What it waits for, in its own words, when `activity` is `waiting` and it says.
        package var waitingFor: String?
        /// When `activity` last changed: a transition time, not a heartbeat.
        package var since: Date?

        private enum CodingKeys: String, CodingKey {
            case activity
            case sinceMs = "since_ms"
        }
        private enum ActivityKeys: String, CodingKey {
            case kind
            case waitingFor = "waiting_for"
        }

        package init(activity: String, waitingFor: String? = nil, since: Date? = nil) {
            self.activity = activity
            self.waitingFor = waitingFor
            self.since = since
        }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let a = try c.nestedContainer(keyedBy: ActivityKeys.self, forKey: .activity)
            activity = try a.decode(String.self, forKey: .kind)
            waitingFor = try a.decodeIfPresent(String.self, forKey: .waitingFor)
            since = try c.decodeIfPresent(UInt64.self, forKey: .sinceMs).map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            }
        }
    }

    /// `bench_wire::Waiting`: what for, since when, and who said so — the agent's hook, or a
    /// prompt benchd read off its screen.
    package struct Waiting: Decodable, Equatable, Sendable {
        package var waitingFor: String
        package var since: Date
        package var source: String

        private enum CodingKeys: String, CodingKey {
            case source
            case waitingFor = "waiting_for"
            case sinceMs = "since_ms"
        }

        package init(waitingFor: String, since: Date, source: String) {
            self.waitingFor = waitingFor
            self.since = since
            self.source = source
        }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            waitingFor = try c.decode(String.self, forKey: .waitingFor)
            since = Date(
                timeIntervalSince1970: Double(try c.decode(UInt64.self, forKey: .sinceMs)) / 1000)
            source = try c.decode(String.self, forKey: .source)
        }
    }

    /// The foreground pid of each pane that shows a live session.
    package var foregroundByPane: [UUID: Int32] { byPane.compactMapValues(\.foregroundPid) }

    /// The agent waiting on the operator in each pane that shows one.
    package var waitingByPane: [UUID: Waiting] { byPane.compactMapValues(\.waiting) }

    /// What the agent in each pane says it is doing, for each pane where one reports.
    package var reportByPane: [UUID: Report] { byPane.compactMapValues(\.report) }

    /// Each pane's live session: one with a foreground process. A pane can also be listed
    /// against a session that ended before it got a new one, and that one says nothing.
    private var byPane: [UUID: Entry] {
        Dictionary(
            sessions.filter { $0.foregroundPid != nil }.compactMap { entry in
                entry.pane.map { ($0, entry) }
            },
            uniquingKeysWith: { first, _ in first })
    }
}

/// `bench_wire::Usage` (#143): how close one harness's plan is to its limits, as the harness
/// itself published it (Claude's statusline, codex's rollout) and benchd last heard it.
package struct BenchUsage: Decodable, Equatable, Sendable {
    /// `claude` or `codex`, as benchd spells it.
    package var harness: String
    package var windows: [Window]

    package init(harness: String, windows: [Window]) {
        self.harness = harness
        self.windows = windows
    }

    /// One limit window (`bench_wire::UsageWindow`).
    package struct Window: Decodable, Equatable, Sendable {
        /// Its length: 300 is five hours, 10080 seven days.
        package var minutes: Int
        /// How much of its allowance is used, 0-100.
        package var usedPercent: Double
        /// When it resets; nil when the harness did not say.
        package var resetsAt: Date?
        /// When the harness last showed this figure: what makes it stale.
        package var at: Date

        private enum CodingKeys: String, CodingKey {
            case minutes
            case usedPercent = "used_percent"
            case resetsAtMs = "resets_at_ms"
            case atMs = "at_ms"
        }

        package init(minutes: Int, usedPercent: Double, resetsAt: Date?, at: Date) {
            self.minutes = minutes
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.at = at
        }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            minutes = try c.decode(Int.self, forKey: .minutes)
            usedPercent = try c.decode(Double.self, forKey: .usedPercent)
            resetsAt = try c.decodeIfPresent(UInt64.self, forKey: .resetsAtMs).map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            }
            at = Date(
                timeIntervalSince1970: Double(try c.decode(UInt64.self, forKey: .atMs)) / 1000)
        }
    }
}
