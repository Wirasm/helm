import Foundation

extension JSONDecoder {
    /// Archon emits SQLite datetimes — `2026-08-03 16:18:09`, space-separated, no zone and no
    /// fractional seconds. Measured against `workflow runs --json` and `workflow get --json
    /// --verbose` on Archon 0.7.0; every one of them, every row.
    ///
    /// This first assumed ISO8601 and the feature did not work AT ALL: a date decode failure
    /// throws rather than yielding nil, every run carries `started_at`, so every call threw and
    /// both the rail and the pane rendered "unavailable" against a live install. 514 tests
    /// passed the whole time, because the fixtures were hand-written in the same imagined
    /// shape as the decoder. Hence `Tests/HelmTests/Archon/Fixtures/`, captured from the CLI
    /// rather than typed — those files, not this comment, are what keep this honest.
    ///
    /// ISO8601 is still accepted afterwards. Nothing observed emits it, but it costs one
    /// fallback and Archon is a separate repo that may start.
    static func archon() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = ArchonDate.parse(string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "invalid Archon date: \(string)")
        }
        return decoder
    }
}

/// The one place that knows what an Archon timestamp looks like, so a second format is added
/// once rather than wherever it is first noticed.
enum ArchonDate {
    /// UTC because the datetimes carry no zone; Archon stores them in UTC.
    private static let sqlite: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        if let date = sqlite.date(from: string) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }
}

// MARK: - What a pane is pointed at

/// The stable address persisted by a workbench pane. Volatile run and node state is resolved
/// from the CLI when the pane is visible.
///
/// **Two cases because the rail has two ways in.** A running run is a line you click to read
/// its nodes; every other status is one collapsed count, and clicking *that* has to land
/// somewhere. It lands on the bench, in a pane addressed by the status — which keeps the rail
/// collapsed (#142's whole point) and is the only route to a finished run now that the rail
/// no longer lists them.
enum ArchonPaneRef: Equatable, Sendable {
    /// One run's node fold. `workflowName` rides along so a tab has a title before the first
    /// poll answers, and after Archon has forgotten the run entirely.
    case run(id: String, workflowName: String)
    /// Every run Archon reports with this status. A raw string for the same reason
    /// `ArchonRun.status` is one.
    case runs(status: String)

    /// What the tab and the pane header say.
    var title: String {
        switch self {
        case let .run(_, workflowName): workflowName
        case let .runs(status): status
        }
    }
}

/// Hand-written with a string discriminator, for the reason `Pane.Content`'s encoder gives:
/// the synthesized shape uses positional `_0` keys, which break on any reordering of the cases
/// and are unreadable in the stored blob.
extension ArchonPaneRef: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id, workflowName, status }
    private enum Kind: String, Codable { case run, runs }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .run:
            self = .run(
                id: try container.decode(String.self, forKey: .id),
                workflowName: try container.decode(String.self, forKey: .workflowName))
        case .runs:
            self = .runs(status: try container.decode(String.self, forKey: .status))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .run(id, workflowName):
            try container.encode(Kind.run, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(workflowName, forKey: .workflowName)
        case let .runs(status):
            try container.encode(Kind.runs, forKey: .kind)
            try container.encode(status, forKey: .status)
        }
    }
}

// MARK: - What the CLI says

/// One row from `archon workflow runs --json`, and the superset returned by verbose
/// `workflow get`. Run status remains a string so a newer Archon status is still visible.
///
/// `current_step_name` and `total_steps` were modelled here and are NOT emitted by
/// `workflow get` — only by `workflow runs`, where they are populated from step events that a
/// DAG workflow never writes. Both were `null` on every row of the captured fixture. They
/// decoded to nil forever and the rail's step subtitle could never render, silently, because
/// both were Optional. The subline reads `nodes` instead, which is populated.
struct ArchonRun: Codable, Equatable, Sendable {
    let id: String
    let workflowName: String
    let status: String
    let workingPath: String?
    let startedAt: Date?
    let completedAt: Date?
    let metadata: Metadata?
    let nodes: [ArchonNode]?

    struct Metadata: Codable, Equatable, Sendable {
        let error: String?
    }

    /// The node the subline animates: the one Archon says is running, else the last one it
    /// reported. **Last rather than first** — `nodes` arrives in DAG order, and a fan-out
    /// leaves several completed nodes after the interesting one.
    var currentNode: ArchonNode? {
        guard let nodes, !nodes.isEmpty else { return nil }
        return nodes.last { $0.state == .running } ?? nodes.last
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, metadata, nodes
        case workflowName = "workflow_name"
        case workingPath = "working_path"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

struct ArchonNode: Codable, Equatable, Sendable {
    /// Open, for the same reason `ArchonRun.status` is a raw string: this vocabulary lives in
    /// another repo that has "zero knowledge" of helm, so it grows without warning.
    ///
    /// It was a closed enum, and the cost was disproportionate — one unrecognised state failed
    /// its node, which failed the whole `nodes` array, which failed the entire run decode, so a
    /// single new state name blanked a healthy run's pane. `running`, `completed`, `failed` and
    /// `skipped` were all seen in one run on the day this was written; nothing suggests that is
    /// the complete list.
    enum State: Equatable, Sendable {
        case running, completed, failed, skipped
        case unknown(String)

        init(raw: String) {
            switch raw {
            case "running": self = .running
            case "completed": self = .completed
            case "failed": self = .failed
            case "skipped": self = .skipped
            default: self = .unknown(raw)
            }
        }

        /// What Archon called it — the unrecognised name survives to the operator rather than
        /// being flattened into a guess.
        var raw: String {
            switch self {
            case .running: "running"
            case .completed: "completed"
            case .failed: "failed"
            case .skipped: "skipped"
            case let .unknown(name): name
            }
        }
    }

    let nodeId: String
    let state: State
    let startedAt: Date?
    let durationMs: Int?
    let outputPreview: String?
    let error: String?
}

extension ArchonNode.State: Codable {
    init(from decoder: any Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

struct ArchonWorkflow: Codable, Equatable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let provider: String?
    let model: String?
}

struct ArchonWorkflowLoadError: Codable, Equatable, Sendable {
    let filename: String
    let error: String
    let errorType: String?
}

/// `archon workflow runs --json`.
///
/// `runs` is capped by the CLI at 20 rows while `counts` is over the whole filtered set, so
/// the two disagree by design — 20 rows against 128 counted, in the captured fixture.
struct ArchonRunsResponse: Codable, Equatable, Sendable {
    let runs: [ArchonRun]
    let total: Int
    /// Archon emits a fixed key set today (`all`, `running`, `completed`, `failed`,
    /// `cancelled`, `pending`, `paused`) but sums `all` over *every* status row, including any
    /// it has not named yet. A dictionary is therefore both the honest shape and the one that
    /// shows a new status without a helm change.
    let counts: [String: Int]
    /// True when Archon wanted to scope to this project and could not, and answered with every
    /// run on the machine instead.
    ///
    /// **Load-bearing, not a curiosity.** A git worktree is not the codebase's registered
    /// directory, so a workspace opened the way `AGENTS.md` tells agents to open one falls back
    /// — verified: 1 run scoped from the main checkout, 128 unscoped from its worktree. Archon
    /// went out of its way to say so in `--json` rather than let an agent mistake a global
    /// answer for a project one; helm passes that on for the same reason.
    let scopeFallback: Bool

    /// The collapsed status lines, in the order the rail shows them: the ones you act on
    /// first, then the rest alphabetically so a status Archon adds later has a defined place
    /// rather than a random one. `all` is dropped — it is a total, not a status.
    static let statusOrder = ["running", "paused", "failed", "completed", "cancelled", "pending"]

    var statusCounts: [ArchonStatusCount] {
        counts
            .filter { $0.key != "all" && $0.value > 0 }
            .map { ArchonStatusCount(status: $0.key, count: $0.value) }
            .sorted { left, right in
                let leftRank =
                    Self.statusOrder.firstIndex(of: left.status) ?? Self.statusOrder.count
                let rightRank =
                    Self.statusOrder.firstIndex(of: right.status) ?? Self.statusOrder.count
                if leftRank != rightRank { return leftRank < rightRank }
                return left.status < right.status
            }
    }
}

struct ArchonStatusCount: Equatable, Sendable, Identifiable {
    var id: String { status }
    let status: String
    let count: Int
}

struct ArchonWorkflowListResponse: Codable, Equatable, Sendable {
    let workflows: [ArchonWorkflow]
    let errors: [ArchonWorkflowLoadError]
}

struct ArchonLaunchAcknowledgement: Codable, Equatable, Sendable {
    let ok: Bool
    let action: String
    let detached: Bool
    let workflow: String
    let branch: String?
    let conversationId: String
    let logPath: String?
}

// MARK: - What Enter launches

/// How a launch isolates itself, as the three states Archon actually has.
///
/// **The `Bool` + `String?` it replaces could describe states that do not exist**:
/// `(noWorktree: true, branch: "x")` silently dropped the branch, and
/// `(noWorktree: false, branch: nil)` was rejected by a guard rather than by the type.
///
/// `automatic` is the third state and it is not padding: passing neither flag is what the CLI
/// is built around — it mints `<workflow>-<epoch-ms>` and cuts a worktree there (verified in
/// `workflow.ts`'s detach path). It is also the *default* the redesigned rail needs, because
/// the whole point is typing a sentence and pressing Enter; demanding a branch name first
/// would put back the third click this shape exists to remove.
enum WorktreeChoice: Codable, Equatable, Sendable {
    /// Let Archon name the branch and cut the worktree.
    case automatic
    /// `--no-worktree` — run on the branch that is checked out.
    case none
    /// `--branch <name>` — a worktree on a branch the operator named.
    case branch(String)

    var arguments: [String] {
        switch self {
        case .automatic: []
        case .none: ["--no-worktree"]
        case let .branch(name): ["--branch", name]
        }
    }
}

/// What the gear holds: the launch every Enter composes, minus the message.
///
/// **Built to grow.** `archon workflow run` has flags helm does not offer yet — `--from`,
/// `--base`, `--folder` — and each is one property here, one control in the gear, and one
/// entry in `arguments`. The decoder is lenient for exactly that reason: a stored config
/// written before a property existed must still load, or adding a flag silently resets the
/// operator's workflow choice to nothing.
struct ArchonLaunchConfig: Codable, Equatable, Sendable {
    var workflow: String
    var worktree: WorktreeChoice

    static let empty = ArchonLaunchConfig(workflow: "", worktree: .automatic)

    init(workflow: String, worktree: WorktreeChoice) {
        self.workflow = workflow
        self.worktree = worktree
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflow = try container.decodeIfPresent(String.self, forKey: .workflow) ?? ""
        worktree =
            try container.decodeIfPresent(WorktreeChoice.self, forKey: .worktree) ?? .automatic
    }
}

struct ArchonLaunchRequest: Equatable, Sendable {
    let workspacePath: String
    let workflow: String
    let input: String
    let worktree: WorktreeChoice
}
