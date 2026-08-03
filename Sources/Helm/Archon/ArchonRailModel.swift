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
    /// How many rows a bulk dismiss asks Archon to name. Above the CLI's 20-row default
    /// because "dismiss all completed" has to name every completed run or it is not "all";
    /// bounded because the answer is decoded into memory and a project's history has no
    /// ceiling. If a status holds more than this, the remainder stays on the line — visibly,
    /// which is the honest outcome.
    static let bulkDismissLimit = 500

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

    /// The runs that get a line: **running and paused**, minus anything dismissed.
    ///
    /// **Paused is here because it is the one status nothing else in helm can tell you about.**
    /// #40's first sketch gave a line only to `running` and collapsed everything else, which is
    /// right for history and wrong for a gate: a run stopped waiting for approval is the state
    /// where the operator is the blocker, and a rail whose whole purpose is quick actions on
    /// work that is not your current work cannot answer it with a number.
    @Published private(set) var active: [ArchonRun] = []
    /// The collapsed lines, already adjusted for what is on screen above them and for what has
    /// been dismissed — so the two never say the same run twice, and a dismissed status line
    /// actually goes away.
    @Published private(set) var statusCounts: [ArchonStatusCount] = []
    /// Run id → the line the subline animates. Absent for a run whose detail call failed.
    @Published private(set) var previews: [String: String] = [:]
    @Published private(set) var liveness: Liveness = .unknown
    @Published private(set) var isScopeFallback = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLaunching = false
    @Published private(set) var launchFailure: String?
    /// The last verb that failed, said in Archon's own words. Separate from `launchFailure`
    /// because they sit in different halves of the rail and a rejected launch must not be
    /// cleared by a successful abandon.
    @Published private(set) var actionFailure: String?
    /// Runs with a verb in flight, so a row can refuse a second click without disabling the
    /// whole rail. A set rather than a flag: two paused runs are independently actionable.
    @Published private(set) var busyRuns: Set<String> = []
    /// How many runs are hidden in the current workspace. Published so the rail can say so —
    /// a filter with nothing on screen admitting it exists is how a rail starts lying.
    @Published private(set) var dismissedCount = 0
    @Published private(set) var workflows: [ArchonWorkflow] = []
    @Published private(set) var workflowLoadErrors: [ArchonWorkflowLoadError] = []
    @Published private(set) var isLoadingWorkflows = false

    private let client: any ArchonClient
    private let defaults: UserDefaults
    private var dismissals: ArchonDismissals
    /// What Archon last said, kept raw so the derived lines can be recomputed the moment a
    /// dismissal changes without waiting two seconds for the next poll.
    private var lastResponse: ArchonRunsResponse?
    private var commands: Set<AnyCancellable> = []

    init(client: any ArchonClient = ArchonCLI(), defaults: UserDefaults = DefaultsDomain.store) {
        self.client = client
        self.defaults = defaults
        dismissals = ArchonDismissals.load(from: defaults)
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
            lastResponse = nil
            active = []
            statusCounts = []
            previews = [:]
            dismissedCount = 0
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
            lastResponse = response
            recompute(for: workspacePath)
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

    /// The two published lists, derived from Archon's last answer and helm's dismissals.
    ///
    /// **The count arithmetic is the whole point.** Archon's `counts` are over the entire
    /// project while its `runs` array is the newest twenty, so the two are about different
    /// sets by design. A collapsed line therefore has to say *what is not already a line above
    /// it* — subtract the runs shown, subtract what has been dismissed under that status, and
    /// clamp. Without the clamp a run dismissed while `running` and since `completed` drives
    /// its old bucket negative, which is a number no operator should ever be shown.
    private func recompute(for workspacePath: String) {
        // Before the guard: a dismissal made while no poll has landed yet still has to be
        // admitted to, or the footer that says what the rail is hiding is the thing hiding it.
        dismissedCount = dismissals.total(in: workspacePath)
        guard let response = lastResponse else { return }
        active = response.runs.filter {
            $0.isActive && !dismissals.contains($0.id, in: workspacePath)
        }
        let shown = Dictionary(grouping: active, by: \.status).mapValues(\.count)
        statusCounts = response.statusCounts.compactMap { line in
            let remaining =
                line.count - (shown[line.status] ?? 0)
                - dismissals.count(of: line.status, in: workspacePath)
            guard remaining > 0 else { return nil }
            return ArchonStatusCount(status: line.status, count: remaining)
        }
    }

    /// One extra `archon` per active run, per poll — issued concurrently, so they cost latency
    /// once rather than N times (measured: two calls in parallel finish in 0.59s, one alone in
    /// 0.56s). Only runs that have a line are asked about, so the cost is bounded by what is on
    /// screen.
    private func refreshPreviews(in workspacePath: String) async {
        let ids = active.map(\.id)
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

    // MARK: - Acting on a run

    /// One of Archon's own verbs, run against one run.
    ///
    /// **`ok` is checked, not the exit status.** In `--json` mode these commands catch their
    /// own failures, print `{"ok": false, …}` and exit zero — so "the process succeeded" and
    /// "the run was abandoned" are different facts, and only the second one is worth
    /// reporting.
    ///
    /// **An approval that leaves the run parked is finished by resuming it here.** Archon
    /// records the decision in `--json` mode without executing, because executing streams the
    /// workflow's output over the JSON contract; its own interactive form resumes immediately
    /// afterwards, and a rail whose Approve button left the run sitting exactly where it was
    /// would be a control that lies by omission. The resume is reported separately when it
    /// fails, because by then the approval has already been recorded and telling the operator
    /// "approve failed" would be the third wrong answer.
    func act(_ action: ArchonRunAction, on run: ArchonRun, in workspacePath: String?) async {
        guard let workspacePath else {
            actionFailure = Self.noWorkspace
            return
        }
        guard !busyRuns.contains(run.id) else { return }
        busyRuns.insert(run.id)
        actionFailure = nil
        defer { busyRuns.remove(run.id) }
        do {
            let acknowledgement = try await client.act(action, on: run.id, in: workspacePath)
            guard acknowledgement.ok else {
                actionFailure =
                    "Archon refused to \(action.verb) this run: "
                    + (acknowledgement.error ?? "no reason given")
                return
            }
            if action.mayResume, acknowledgement.leavesRunResumable {
                do {
                    let resumed = try await client.resume(run)
                    if !resumed.ok || !resumed.detached {
                        actionFailure =
                            "\(action.verb.capitalized) recorded, but Archon did not restart the "
                            + "run. Resume it from a terminal."
                    }
                } catch {
                    actionFailure =
                        "\(action.verb.capitalized) recorded, but the run did not restart: "
                        + error.localizedDescription
                }
            }
        } catch {
            actionFailure = error.localizedDescription
        }
        await refresh(in: workspacePath)
    }

    // MARK: - Dismissing from this rail

    /// Stops showing one run here. **Not a delete** — see `ArchonDismissals`.
    func dismiss(_ run: ArchonRun, in workspacePath: String?) {
        guard let workspacePath else { return }
        record([ArchonDismissal(id: run.id, status: run.status)], in: workspacePath)
    }

    /// Stops showing every run Archon reports with this status.
    ///
    /// **It asks Archon for the ids rather than assuming them**, because the rail's number
    /// comes from `counts` — computed over the whole project — while the rows come from the
    /// newest twenty. Dismissing what happened to be on hand would take a line reading 128
    /// down to 108 and look like a bug. A status holding more than `bulkDismissLimit` keeps
    /// its remainder on the line, which is the visible, honest outcome.
    func dismissAll(status: String, in workspacePath: String?) async {
        guard let workspacePath else { return }
        actionFailure = nil
        do {
            let response = try await client.runs(
                in: workspacePath, status: status, limit: Self.bulkDismissLimit)
            record(
                response.runs.map { ArchonDismissal(id: $0.id, status: $0.status) },
                in: workspacePath)
        } catch {
            actionFailure = error.localizedDescription
        }
    }

    /// The undo, and the reason dismissal is allowed to be this casual.
    func restoreDismissed(in workspacePath: String?) {
        guard let workspacePath else { return }
        dismissals.restoreAll(in: workspacePath)
        dismissals.save(to: defaults)
        recompute(for: workspacePath)
    }

    private func record(_ entries: [ArchonDismissal], in workspacePath: String) {
        dismissals.dismiss(entries, in: workspacePath)
        dismissals.save(to: defaults)
        // Recomputed rather than left to the next tick: two seconds of a row still sitting
        // there after it was dismissed reads as a control that did not work.
        recompute(for: workspacePath)
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
