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
    /// Where the run is working — the worktree Archon cut for it, when it cut one.
    let workingPath: String?
    /// The instruction the run was started with.
    let userMessage: String?
    let startedAt: Date?
    let completedAt: Date?
    let metadata: Metadata?
    let nodes: [ArchonNode]?

    struct Metadata: Codable, Equatable, Sendable {
        let error: String?
        /// The gate a paused run is waiting at. Written by `pauseWorkflowRun` and carried
        /// whole into `workflow runs --json`, so it costs no extra call — see `ArchonGate`.
        let approval: ArchonGate?

        init(error: String?, approval: ArchonGate?) {
            self.error = error
            self.approval = approval
        }

        /// **A gate helm cannot read costs the gate, never the run.** `ArchonGate` already
        /// tolerates missing keys; this handles the other shape — `approval` present but not
        /// an object at all, which a stale run can carry and which would otherwise throw
        /// through the whole `runs` decode and blank the rail.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            error = try container.decodeIfPresent(String.self, forKey: .error)
            approval = try? container.decodeIfPresent(ArchonGate.self, forKey: .approval)
        }
    }

    /// The eight characters `workflow runs` prints and every Archon surface identifies a run
    /// by — including `archon workflow get <short-id>`, which resolves a prefix. What the rail
    /// shows, so what is on screen is what you would type.
    var shortID: String { String(id.prefix(8)) }

    /// The one status that gets a live line of its own.
    var isRunning: Bool { status == ArchonRunStatus.running }

    /// Stopped, waiting for a person. The status that gets the rail's top line.
    var isPaused: Bool { status == ArchonRunStatus.paused }

    /// The two statuses that put a run in the inbox.
    ///
    /// **`cancelled` is deliberately absent**: the operator ended it themselves, so it is not
    /// news, and it produced nothing to be handed. `paused` is not finished either — it has its
    /// own list, above the running one, because it is the one state blocked on the operator.
    var isFinished: Bool {
        status == ArchonRunStatus.completed || status == ArchonRunStatus.failed
    }

    /// The gate holding this run, when there is one.
    ///
    /// **Only meaningful while `paused`.** Archon never clears the approval context on resume —
    /// it is deliberately kept for the executor's resume-time reads — so a completed run still
    /// carries the last gate it passed, and reading it on any other status would put a stale
    /// question under a finished row.
    var gate: ArchonGate? { isPaused ? metadata?.approval : nil }

    /// Whether this run is waiting on **the operator**, as opposed to merely being paused.
    /// A paused run with no gate at all, a gate already answered, or a gate belonging to a
    /// sub-run are all paused and none of them is yours — see `ArchonGate.isAwaitingDecision`.
    var isAwaitingDecision: Bool { gate?.isAwaitingDecision ?? false }

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
        case userMessage = "user_message"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

/// The status words, in one place.
///
/// **Strings rather than an enum, for the reason `ArchonRun.status` is one**: this vocabulary
/// lives in a repo that has zero knowledge of helm and grows without warning. These are the
/// ones helm has to *reason* about — everything else it only has to display, which needs no
/// name here.
///
/// Archon declares `RunStatus = 'running' | 'paused' | 'failed' | 'completed' | 'cancelled'`.
/// `pending`, `error` and `aborted` also appear in its source but belong to nodes and
/// workflows, not runs.
enum ArchonRunStatus {
    static let running = "running"
    static let paused = "paused"
    static let completed = "completed"
    static let failed = "failed"
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

    /// The stage's name — `parse-request`, `implement`, `validate`. What the rail's subline
    /// says, because it is the thing that *advances*.
    ///
    /// **Node keys are camelCase while the run's own are snake_case**, which is a real
    /// asymmetry in Archon's output rather than a typo here — verified against
    /// `workflow get --json --verbose` on 0.7.0, and captured in
    /// `Tests/HelmTests/Archon/Fixtures/`.
    let nodeId: String
    let state: State
    let startedAt: Date?
    let durationMs: Int?
    /// Archon's ~200-character excerpt of what the node wrote. Decoded because it is part of
    /// a node; not rendered, because reading a run happens in Archon's own UI.
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

extension ArchonRunsResponse {
    /// The tint a collapsed count carries, and it is **Archon's status mapping, not its
    /// brand**. The console keeps the two apart on purpose — *"status colours are kept
    /// distinct from accent so brand swaps don't break meaning"* — so a failed run is red and
    /// a completed one is the brand teal because teal is what `--success` points at, never
    /// because everything Archon is magenta.
    static func tint(for status: String) -> ArchonStatusTint {
        switch status {
        case "running": .running
        case "completed": .success
        case "failed": .error
        case "paused": .warning
        default: .neutral
        }
    }
}

/// Which token a status spends. An enum rather than a `Color` so the mapping is a value the
/// tests can read, in the same spirit as `Palette` itself.
enum ArchonStatusTint: Equatable, Sendable {
    case running, success, error, warning, neutral
}
