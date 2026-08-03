import Combine
import Foundation

/// The rail's one tenant, **input first**.
///
/// **The shape this replaces was list-first with the launcher behind a `+`, and the operator's
/// verdict on it was "stale and hard to use".** He runs the same workflow over and over, so the
/// common case has to cost zero clicks and it cost three: open the popover, pick the workflow,
/// type, submit. Here the field is always there, Enter launches against whatever the gear
/// holds, and the list below it collapses to one line per status — because a list you are not
/// acting on is not what a rail is for (#142).
@MainActor
final class ArchonRailModel: ObservableObject {
    static let visibilityKey = "archonRailVisible"
    static let configKey = "archonLaunchConfig"
    /// One string, one guard. It was written out twice and the copies were already drifting.
    static let noWorkspace = "Open a workspace before starting an Archon workflow."

    /// Whether the last poll got an answer.
    ///
    /// **There is no Archon daemon to be up or down** — `archon` is a CLI helm invokes per
    /// poll — so "live" can only mean *the last invocation succeeded*. Worth having anyway:
    /// before it, "no runs" and "cannot reach Archon" rendered identically, and the second one
    /// is the state where nothing you do in this rail will work.
    enum Liveness: Equatable {
        /// No poll has finished yet, or there is no workspace to poll about.
        case unknown
        case live
        case unreachable(String)
    }

    @Published private(set) var isVisible: Bool
    /// What the operator is typing. Owned by the view's field, so not `private(set)`.
    ///
    /// Editing it clears the last rejection. Every rejection below is about the draft or the
    /// gear, so acting on either means the sentence under the field is about a state that no
    /// longer exists — and a red line that outlives its cause is the kind of thing you learn
    /// to stop reading.
    @Published var draft = "" { didSet { launchFailure = nil } }
    @Published var isConfigOpen = false
    /// Persisted on every change rather than on close: the gear is a popover, and a popover
    /// dismissed by clicking away fires nothing helm can hang a save on.
    @Published var config: ArchonLaunchConfig {
        didSet {
            launchFailure = nil
            persist(config)
        }
    }

    @Published private(set) var running: [ArchonRun] = []
    @Published private(set) var statusCounts: [ArchonStatusCount] = []
    /// Run id → the line the subline animates. Absent for a run whose detail call failed.
    @Published private(set) var previews: [String: String] = [:]
    @Published private(set) var liveness: Liveness = .unknown
    @Published private(set) var isScopeFallback = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLaunching = false
    @Published private(set) var launchFailure: String?
    @Published private(set) var workflows: [ArchonWorkflow] = []
    @Published private(set) var workflowLoadErrors: [ArchonWorkflowLoadError] = []
    @Published private(set) var isLoadingWorkflows = false

    private let client: any ArchonClient
    private let defaults: UserDefaults
    private var commands: Set<AnyCancellable> = []

    init(client: any ArchonClient = ArchonCLI(), defaults: UserDefaults = DefaultsDomain.store) {
        self.client = client
        self.defaults = defaults
        isVisible = defaults.bool(forKey: Self.visibilityKey)
        config =
            defaults.data(forKey: Self.configKey)
            .flatMap { try? JSONDecoder().decode(ArchonLaunchConfig.self, from: $0) }
            ?? .empty
        NotificationCenter.default.publisher(for: .helmToggleRail)
            // Hopped to main because `@Published` fires in `willSet`: a handler that read
            // state synchronously would see the value from *before* the change. The same
            // reason `WorkbenchModel.subscribe` gives, and the same shape.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // The hop above guarantees the main thread but not main-actor *isolation*,
                // which Swift 6 requires separately. `assumeIsolated` asserts what
                // `.receive(on: DispatchQueue.main)` has already made true; the alternative
                // is a `Task { @MainActor in … }` per notification, which would also reorder
                // ⇧⌘R against anything else queued.
                MainActor.assumeIsolated { self?.toggleVisibility() }
            }
            .store(in: &commands)
    }

    /// ⇧⌘R, and the reason the subscription above lives on the model: the rail is hidden by
    /// default, so the view that would otherwise own it does not exist in the one state the
    /// shortcut has to work in.
    func toggleVisibility() {
        isVisible.toggle()
        defaults.set(isVisible, forKey: Self.visibilityKey)
    }

    func poll(in workspacePath: String?, every interval: Duration = ArchonPolling.interval) async {
        await ArchonPolling.loop(every: interval) { await refresh(in: workspacePath) }
    }

    func refresh(in workspacePath: String?) async {
        guard let workspacePath else {
            running = []
            statusCounts = []
            previews = [:]
            isScopeFallback = false
            liveness = .unknown
            return
        }
        // Drop rather than queue: a poll that overran its interval means Archon is slower than
        // the tick, and stacking a second call behind it would put helm further behind on
        // every tick until the CLI is answering a queue instead of a question. The next tick
        // is 2s away and asks the same thing.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let response = try await client.runs(in: workspacePath, status: nil)
            running = response.runs.filter { $0.status == "running" }
            statusCounts = response.statusCounts
            isScopeFallback = response.scopeFallback
            liveness = .live
            await refreshPreviews(in: workspacePath)
        } catch is CancellationError {
            return
        } catch {
            // The last known runs are kept. A single failed poll is usually a hiccup, and
            // blanking the rail for it would make the list flap; the liveness dot is what
            // says the lines below it are stale.
            liveness = .unreachable(error.localizedDescription)
        }
    }

    /// One extra `archon` per running run, per poll — issued concurrently, so a running run
    /// costs latency once rather than N times (measured: two calls in parallel finish in
    /// 0.59s, one alone in 0.56s). Only `running` runs are asked about, and only running runs
    /// get a line, so the cost is bounded by what is on screen.
    private func refreshPreviews(in workspacePath: String) async {
        let ids = running.map(\.id)
        guard !ids.isEmpty else {
            previews = [:]
            return
        }
        let client = self.client
        var fetched: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for id in ids {
                group.addTask {
                    // A detail call that fails costs that run its subline and nothing else.
                    // The run itself is already on screen from the list call; failing the
                    // whole refresh here would trade a missing line for a missing rail.
                    guard let run = try? await client.run(id: id, in: workspacePath) else {
                        return (id, nil)
                    }
                    return (id, run.currentNode?.previewLine)
                }
            }
            for await (id, preview) in group {
                if let preview { fetched[id] = preview }
            }
        }
        previews = fetched
    }

    /// Opening the gear is what loads the workflow list — the rail does not need it to poll,
    /// and `workflow list` reads every workflow file in the project on every call.
    func loadWorkflows(in workspacePath: String?) async {
        isConfigOpen = true
        launchFailure = nil
        guard let workspacePath else {
            launchFailure = Self.noWorkspace
            return
        }
        isLoadingWorkflows = true
        defer { isLoadingWorkflows = false }
        do {
            let response = try await client.workflows(in: workspacePath)
            workflows = response.workflows
            workflowLoadErrors = response.errors
            if config.workflow.isEmpty { config.workflow = workflows.first?.name ?? "" }
        } catch {
            launchFailure = error.localizedDescription
        }
    }

    /// Enter in the field. Everything except the message comes from the gear.
    func launch(in workspacePath: String?) async {
        guard !isLaunching else { return }
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflow = config.workflow.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspacePath else {
            launchFailure = Self.noWorkspace
            return
        }
        guard !workflow.isEmpty else {
            launchFailure = "Choose a workflow in the gear before launching."
            return
        }
        guard !message.isEmpty else {
            launchFailure = "Type what the workflow should do."
            return
        }
        if case let .branch(name) = config.worktree,
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            launchFailure = "Name the branch in the gear, or let Archon name it."
            return
        }

        isLaunching = true
        launchFailure = nil
        defer { isLaunching = false }
        do {
            let acknowledgement = try await client.launch(
                ArchonLaunchRequest(
                    workspacePath: workspacePath, workflow: workflow, input: message,
                    worktree: config.worktree))
            // `--detach` returning `detached: false` would mean Archon ran the whole workflow
            // in this child and helm blocked on it — a different failure from a rejection, and
            // one the operator has to be told about because the field will have cleared.
            guard acknowledgement.ok, acknowledgement.detached else {
                launchFailure = "Archon did not accept the detached launch."
                return
            }
            draft = ""
            await refresh(in: workspacePath)
        } catch {
            launchFailure = error.localizedDescription
        }
    }

    private func persist(_ config: ArchonLaunchConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Self.configKey)
    }
}

extension ArchonNode {
    /// The preview as one line. Archon truncates it to about 200 characters but keeps the
    /// newlines an agent wrote, and a subline that grows to four lines makes the rail jump on
    /// every poll.
    var previewLine: String? {
        guard let outputPreview else { return nil }
        let collapsed = outputPreview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
