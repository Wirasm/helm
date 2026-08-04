import Combine
import Foundation

/// The rail's one tenant: **a place to start Archon work, and the smallest possible answer to
/// "is anything happening?"**
///
/// **This is the reduction of a rail that was built, used and cut back.** The version before
/// it opened runs as workbench panes, listed finished runs, carried Archon's `approve`,
/// `reject` and `abandon` verbs, kept a per-workspace dismissal filter, and said whether the
/// CLI had answered. The operator's verdict on all of it was *"too much bloat, I want to start
/// simple"*. What is left renders five things and nothing else: a title, a field, a send
/// button, one line per **running** run with a subline naming its current stage, and one
/// collapsed count per other status. Run detail is read in Archon's own web UI.
///
/// **The bottom of the rail is an inbox, not a ledger.** It was a tally — `3 COMPLETED`,
/// `1 FAILED` — and a tally is the wrong signal twice over. It cannot be acted on, and it could
/// be wrong by two orders of magnitude without saying so: Archon answers a git worktree with
/// every run on the machine (`scopeFallback`, measured at 1 against 128), and a bare number
/// gives the operator no way to notice. A finished run now gets one dismissible line that opens
/// what it produced. Clearing one removes it **from helm only**, which is honest here in a way
/// it was not before, because a list of runs you have not cleared never claimed to be history.
///
/// **`paused` has no surface at all now, and that is a real subtraction.** It had a number; the
/// numbers are gone, and a paused run is not finished so it does not reach the inbox. Giving it
/// a row means putting Archon's approve/reject verbs back, which this rail removed on purpose —
/// so it is left visibly missing rather than quietly half-solved.
@MainActor
final class ArchonRailModel: ObservableObject {
    static let visibilityKey = "archonRailVisible"
    static let configKey = "archonLaunchConfig"
    /// One string, one guard. It was written out twice and the copies were already drifting.
    static let noWorkspace = "Open a workspace before starting an Archon workflow."

    @Published private(set) var isVisible: Bool
    /// What the operator is typing. Owned by the view's field, so not `private(set)`.
    ///
    /// Editing it clears the last rejection. Every rejection is about the draft or the
    /// settings, so acting on either means the sentence under the field is about a state that
    /// no longer exists — and a red line that outlives its cause is the kind of thing you
    /// learn to stop reading.
    @Published var draft = "" { didSet { launchFailure = nil } }
    @Published var isConfigOpen = false
    /// Persisted on every change rather than on close: the settings are a popover, and a
    /// popover dismissed by clicking away fires nothing helm can hang a save on.
    @Published var config: ArchonLaunchConfig {
        didSet {
            launchFailure = nil
            persist(config)
        }
    }

    /// The runs that get a live line. Only `running` — see the note on the type.
    @Published private(set) var running: [ArchonRun] = []
    /// Finished runs the operator has not cleared, newest first. Bounded by what Archon
    /// returns — its `runs` array is capped at 20 — so this is the recent post, not an archive.
    @Published private(set) var finished: [ArchonRun] = []
    /// Run id → the stage its subline names. Absent for a run whose detail call failed.
    @Published private(set) var stages: [String: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLaunching = false
    /// **The one piece of text here that is not in the rail's list, and it is deliberate.**
    /// Everything ambient was cut — no liveness word, no empty-state prose, no footer — but a
    /// send button that silently does nothing is a worse defect than a line of text, and this
    /// is the only place Archon's own reason for refusing a launch can be read.
    @Published private(set) var launchFailure: String?
    @Published private(set) var workflows: [ArchonWorkflow] = []
    @Published private(set) var workflowLoadErrors: [ArchonWorkflowLoadError] = []
    @Published private(set) var isLoadingWorkflows = false

    private let client: any ArchonClient
    private let defaults: UserDefaults
    private let opener: ArchonRunOpener
    /// Not `@Published`: nothing renders the dismissals themselves, only their effect on
    /// `finished`, and publishing a store the view never reads would invalidate it for nothing.
    private var dismissals: ArchonInboxDismissals
    private var commands: Set<AnyCancellable> = []

    init(
        client: any ArchonClient = ArchonCLI(), defaults: UserDefaults = DefaultsDomain.store,
        opener: ArchonRunOpener = .live
    ) {
        self.client = client
        self.defaults = defaults
        self.opener = opener
        // Pruned on the way in rather than on a timer: it is the only moment the store is
        // certain to be read, and an age-out that only runs while helm is open is exactly as
        // good as one that runs on launch.
        var loaded = ArchonInboxDismissals.load(from: defaults)
        loaded.prune(now: Date())
        dismissals = loaded
        loaded.save(to: defaults)
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
            finished = []
            stages = [:]
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
            let response = try await client.runs(in: workspacePath)
            apply(response, in: workspacePath)
            await refreshStages(in: workspacePath)
        } catch is CancellationError {
            return
        } catch {
            // The last known runs are kept and the failure is swallowed. A single failed poll
            // is usually a hiccup, and blanking the rail for it would make the lines flap —
            // but there is deliberately nothing on screen that says so any more, which is the
            // price of the rail rendering five things (see the type's note).
            return
        }
    }

    /// The two published lists, derived from Archon's last answer.
    ///
    /// **Both come from `runs`, and `counts` is now ignored entirely.** They were always about
    /// different sets — `counts` spans the project (or the machine, under `scopeFallback`)
    /// while `runs` is the newest twenty — and the arithmetic that reconciled them existed only
    /// to keep a tally honest. There is no tally left to keep honest.
    private func apply(_ response: ArchonRunsResponse, in workspacePath: String) {
        running = response.runs.filter(\.isRunning)
        finished =
            response.runs
            .filter { $0.isFinished && !dismissals.contains($0.id, in: workspacePath) }
            .sorted { left, right in
                // `completed_at` is what the operator means by "the last one to finish", and a
                // run missing it sorts last rather than crashing the comparison.
                (left.completedAt ?? .distantPast) > (right.completedAt ?? .distantPast)
            }
    }

    /// Clear one finished run. **From helm only** — Archon's record is untouched, which is
    /// exactly why this list must never present itself as history.
    func dismiss(_ run: ArchonRun, in workspacePath: String?) {
        guard let workspacePath else { return }
        dismissals.dismiss(run.id, in: workspacePath, now: Date())
        dismissals.save(to: defaults)
        finished.removeAll { $0.id == run.id }
    }

    /// Open what a finished run produced — its pull request, or the branch it would come from.
    /// Resolved on click and never on the poll, so an inbox of twenty costs nothing until one
    /// of them is asked about.
    func open(_ run: ArchonRun) {
        let opener = self.opener
        Task { await opener.open(run) }
    }

    /// One extra `archon` per running run, per poll — issued concurrently, so they cost latency
    /// once rather than N times (measured: two calls in parallel finish in 0.59s, one alone in
    /// 0.56s). Only runs that have a line are asked about, so the cost is bounded by what is on
    /// screen, and in practice that is nought or one.
    private func refreshStages(in workspacePath: String) async {
        let ids = running.map(\.id)
        guard !ids.isEmpty else {
            stages = [:]
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
                    return (id, run.currentNode?.nodeId)
                }
            }
            for await (id, stage) in group {
                if let stage { fetched[id] = stage }
            }
        }
        stages = fetched
    }

    /// Opening the settings is what loads the workflow list — the rail does not need it to
    /// poll, and `workflow list` reads every workflow file in the project on every call.
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

    /// Enter in the field, or the send button. Everything except the message comes from the
    /// settings.
    func launch(in workspacePath: String?) async {
        guard !isLaunching else { return }
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflow = config.workflow.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspacePath else {
            launchFailure = Self.noWorkspace
            return
        }
        guard !workflow.isEmpty else {
            launchFailure = "Choose a workflow in the settings before launching."
            return
        }
        guard !message.isEmpty else {
            launchFailure = "Type what the workflow should do."
            return
        }
        if case let .branch(name) = config.worktree,
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            launchFailure = "Name the branch in the settings, or let Archon name it."
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
            //
            // **`ok` is checked, not the exit status**, which is the rule for every `--json`
            // verb: they catch their own failures, print `{"ok": false, …}` and exit zero.
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
