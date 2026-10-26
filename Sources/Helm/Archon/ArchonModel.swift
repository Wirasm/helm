import Combine
import Foundation

/// The Archon drawer's model (#382): what Archon is doing in the active workspace's project, and
/// the verbs the operator answers it with.
///
/// **Three lists.** `queue` (Archon's attention queue, the only rows blocked on the operator,
/// so they come first), `running`, and `finished` (completed or failed runs he has not
/// cleared). `workflow attention --json` answers the first; `workflow runs --json` the other
/// two, with each run's stage list; when any run is live, `workflow status --json --verbose`
/// adds the per-node fold its stage dots are coloured from. A refresh is two or three `archon`
/// processes whatever the number of runs.
///
/// **What is still deliberately absent.** This is the successor of a rail the operator cut back
/// as *"too much bloat"*: no counts or tallies (a number cannot be acted on, and under
/// `scopeFallback` it can be wrong by two orders of magnitude), no liveness word, no run pane.
/// Depth is a keystroke away instead: a run's log in a terminal, its pull request, or Archon's
/// own web UI.
///
/// **Finished runs are an inbox, not a ledger.** Clearing one hides it in helm only; Archon's
/// record is untouched.
///
/// **One input with two jobs.** Choosing an answer retargets the composer; the launch draft is
/// held aside, because losing a half-written instruction to answer an item is the version of
/// this that gets sworn at. Every answer goes through the composer, because Archon records
/// its text with the decision and the SDLC stages write it down as the ruling the next round
/// works from: a bare choice teaches the next round nothing.
///
/// **Nothing polls while the drawer is hidden**, so an item is only seen when the drawer is
/// open. The operator ruled that acceptable for now (2026-09-27, D2 of the plan).
@MainActor
final class ArchonModel: ObservableObject {
    static let configKey = "archonLaunchConfig"
    /// One string, one guard. It was written out twice and the copies were already drifting.
    static let noWorkspace = "Open a workspace before starting an Archon workflow."
    /// What Send launches when nothing usable is chosen, if the workspace has it (#528).
    static let defaultWorkflow = "archon-ship"

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

    /// What the operator is typing **as an answer**, kept apart from `draft` on purpose:
    /// answering must not cost a half-written launch instruction, and one string for both is
    /// exactly how it would.
    @Published var replyText = "" { didSet { actionFailure = nil } }

    /// Archon's attention queue for this project, above everything else.
    @Published private(set) var queue: [ArchonAttentionItem] = []
    /// The runs that get a live line: running, or paused on something that is not the
    /// operator's (a sub-run, a timer, an answer Archon is still continuing).
    @Published private(set) var running: [ArchonRun] = []
    /// Finished runs the operator has not cleared, newest first. Bounded by what Archon
    /// returns — its `runs` array is capped at 20 — so this is the recent post, not an archive.
    @Published private(set) var finished: [ArchonRun] = []
    /// Run id → the per-node fold `workflow status --verbose` gave for that live run. Absent
    /// for a run that call did not answer; its dots then show only where it is.
    @Published private(set) var liveNodes: [String: [ArchonNode]] = [:]
    /// Why the runs could not be listed (#523), or nil. Without it a drawer that cannot reach
    /// Archon at all reads "No Archon runs here yet.", the same as one where Archon never ran.
    @Published private(set) var refreshFailure: String?
    /// Occurrences helm answered that Archon may still list: `respond --detach` acknowledges
    /// before its child records the answer, and the refresh after an answer is skipped while a
    /// poll is in flight. Either way the answered row would come back answerable. Each is
    /// dropped once Archon stops listing it.
    private var answered: Set<String> = []
    /// Failed `runs` calls in a row, so one hiccup can be told from a failure that persists.
    private var failedPolls = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLaunching = false
    /// **The one piece of text here that is not in the drawer's list, and it is deliberate.**
    /// Everything ambient was cut — no liveness word, no empty-state prose, no footer — but a
    /// send button that silently does nothing is a worse defect than a line of text, and this
    /// is the only place Archon's own reason for refusing a launch can be read.
    @Published private(set) var launchFailure: String?
    /// Why the last answer or control did not land. **Separate from `launchFailure`** because a
    /// rejected launch must not be cleared by a successful answer.
    @Published private(set) var actionFailure: String?
    /// The item the composer is currently answering, if any. Nil is the launch composer.
    @Published private(set) var reply: ArchonAnswer?
    /// A set rather than a flag: two items are independently answerable, and a spinner over the
    /// whole drawer would say the wrong thing about the other one.
    @Published private(set) var busyRuns: Set<String> = []
    @Published private(set) var workflows: [ArchonWorkflow] = []
    @Published private(set) var workflowLoadErrors: [ArchonWorkflowLoadError] = []
    @Published private(set) var isLoadingWorkflows = false
    /// Whether the searchable workflow list is open over the run list. On the model
    /// because two views open it: the label under the composer, and `w` in the run list.
    @Published var isPickingWorkflow = false
    /// Why the label shows the workflow it does, when that is not the default: this workspace
    /// has no `archon-ship`, so the first workflow was taken instead. Nil otherwise.
    @Published private(set) var workflowNote: String?
    /// Whose list `workflows` is, so the note is dropped when the workspace changes.
    private var workflowsWorkspace: WorkspacePath?
    /// Counts workflow loads, so a superseded one can tell it is no longer the latest.
    private var workflowLoads = 0
    private let client: any ArchonClient
    private let defaults: UserDefaults
    private let opener: ArchonRunOpener
    /// Not `@Published`: nothing renders the dismissals themselves, only their effect on
    /// `finished`, and publishing a store the view never reads would invalidate it for nothing.
    private var dismissals: ArchonInboxDismissals

    init(
        client: any ArchonClient,
        defaults: UserDefaults = DefaultsDomain.store,
        opener: ArchonRunOpener
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
        config =
            defaults.data(forKey: Self.configKey)
            .flatMap { try? JSONDecoder().decode(ArchonLaunchConfig.self, from: $0) }
            ?? .empty
    }

    func poll(
        in workspacePath: WorkspacePath?, every interval: Duration = ArchonPolling.interval
    ) async {
        await ArchonPolling.loop(every: interval) { await refresh(in: workspacePath) }
    }

    func refresh(in workspacePath: WorkspacePath?) async {
        guard let workspacePath else {
            queue = []
            running = []
            finished = []
            liveNodes = [:]
            failedPolls = 0
            refreshFailure = nil
            disarm()
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
            async let runs = client.runs(in: workspacePath)
            async let attention = client.attention(in: workspacePath)
            let (response, items) = try await (runs, attention)
            failedPolls = 0
            refreshFailure = nil
            apply(response, queue: items.items, in: workspacePath)
            await refreshLiveNodes(in: workspacePath)
        } catch is CancellationError {
            return
        } catch {
            // The last known runs are always kept: blanking the drawer on a hiccup would make
            // the rows flap. One failure after a good poll says nothing either. With no rows
            // to keep, or a second failure in a row, it is not a hiccup and the reason shows.
            failedPolls += 1
            if failedPolls > 1 || (queue.isEmpty && running.isEmpty && finished.isEmpty) {
                refreshFailure =
                    "Could not list Archon runs in \(workspacePath.value): "
                    + error.localizedDescription
            }
        }
    }

    /// The published lists, derived from Archon's last answers. `counts` is ignored: a tally
    /// of a different set (the project, or the machine under `scopeFallback`) from the newest
    /// twenty rows `runs` holds.
    private func apply(
        _ response: ArchonRunsResponse, queue items: [ArchonAttentionItem],
        in workspacePath: WorkspacePath
    ) {
        answered.formIntersection(items.compactMap(\.occurrence))
        queue = items.filter { !answered.contains($0.occurrence ?? "") }
        let queued = Set(items.map(\.runId))
        running = response.runs.filter { $0.isRunning || ($0.isPaused && !queued.contains($0.id)) }
        finished =
            response.runs
            .filter { $0.isFinished && !dismissals.contains($0.id, in: workspacePath) }
            .sorted { left, right in
                // `completed_at` is what the operator means by "the last one to finish", and a
                // run missing it sorts last rather than crashing the comparison.
                (left.completedAt ?? .distantPast) > (right.completedAt ?? .distantPast)
            }
        // An item answered from anywhere — Archon's own UI, a terminal, another helm — takes
        // the composer back with it. Leaving it armed would offer Send against a question
        // already settled.
        //
        // **And it says so.** The field would revert to the launch draft under the operator's
        // hands mid-sentence, and the Enter they were about to press would launch a workflow
        // instead of answering. `busyRuns` marks the answer helm is itself sending, which is the
        // one case the composer is *expected* to lose and needs no sentence.
        if let reply, !items.contains(where: { $0.occurrence == reply.occurrence }) {
            let ours = busyRuns.contains(reply.runID)
            disarm()
            if !ours {
                actionFailure = "That question was answered elsewhere. Nothing was sent."
            }
        }
    }

    /// Clear one finished run. **From helm only** — Archon's record is untouched, which is
    /// exactly why this list must never present itself as history.
    func dismiss(_ run: ArchonRun, in workspacePath: WorkspacePath?) {
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

    // MARK: - Answering the queue

    /// Point the composer at one of an item's answers. The launch draft is untouched — the
    /// field simply binds to the other string until this is sent or cancelled.
    func choose(_ choice: ArchonChoice, on item: ArchonAttentionItem) {
        guard let occurrence = item.occurrence, !busyRuns.contains(item.runId) else { return }
        reply = ArchonAnswer(
            runID: item.runId, occurrence: occurrence, choice: choice,
            workflowName: item.workflow)
        replyText = ""
        actionFailure = nil
    }

    /// Give the composer back to launching. Nothing is sent.
    func disarm() {
        reply = nil
        replyText = ""
    }

    /// Enter in an armed composer, or its send button. The text is optional except for a
    /// `message` wait, whose answer it is: an empty one would be an Enter pressed by accident,
    /// recorded as the operator's reply.
    func sendReply(in workspacePath: WorkspacePath?) async {
        guard let reply else { return }
        guard let workspacePath else {
            actionFailure = Self.noWorkspace
            return
        }
        if reply.choice.needsText,
            replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            actionFailure = "Type the answer first."
            return
        }
        await control(reply.runID, in: workspacePath) {
            let acknowledgement = try await client.answer(
                reply, text: replyText, in: workspacePath)
            if acknowledgement.ok {
                disarm()
                answered.insert(reply.occurrence)
                queue.removeAll { $0.occurrence == reply.occurrence }
            }
            return acknowledgement
        }
    }

    /// Run one control verb against one run, report it on the action line, then refresh.
    ///
    /// **`ok` is checked, not only the exit status**: a `--json` verb reports its refusal in the
    /// payload. **The failure is published last**, after `disarm()` and the refresh, because
    /// both write state whose observers clear `actionFailure`. Refreshed even on a refusal,
    /// and especially then: the commonest reason Archon refuses is that the question was
    /// already answered somewhere else, so the row on screen is the stale thing that produced
    /// the click.
    private func control(
        _ runID: String, in workspacePath: WorkspacePath,
        _ call: () async throws -> ArchonActionAcknowledgement
    ) async {
        guard !busyRuns.contains(runID) else { return }
        busyRuns.insert(runID)
        actionFailure = nil
        defer { busyRuns.remove(runID) }
        var failure: String?
        do {
            let acknowledgement = try await call()
            if !acknowledgement.ok {
                failure = "Archon refused: " + (acknowledgement.error ?? "no reason given")
            }
        } catch {
            failure = error.localizedDescription
        }
        await refresh(in: workspacePath)
        actionFailure = failure
    }

    /// The per-node fold for every live run, from one `workflow status --verbose`. Skipped when
    /// nothing is live, which is the common case, so an idle refresh is one process.
    private func refreshLiveNodes(in workspacePath: WorkspacePath) async {
        guard !running.isEmpty else {
            liveNodes = [:]
            return
        }
        // A failed call costs the dots their colours and nothing else: the rows are already on
        // screen from `runs`, and each still shows where it is from `active_nodes`.
        guard let status = try? await client.status(in: workspacePath) else { return }
        liveNodes = Dictionary(
            status.runs.compactMap { run in run.nodes.map { (run.id, $0) } },
            uniquingKeysWith: { _, last in last })
    }

    /// Stop a running run. Reported like an answer, on the same line.
    func cancel(_ run: ArchonRun, in workspacePath: WorkspacePath?) async {
        guard let workspacePath else {
            actionFailure = Self.noWorkspace
            return
        }
        guard run.isRunning else { return }
        await control(run.id, in: workspacePath) {
            try await client.cancel(runID: run.id, in: workspacePath)
        }
    }

    /// Resume a failed run, or a paused one nothing else will continue, from its completed
    /// nodes.
    func resume(runID: String, in workspacePath: WorkspacePath?) async {
        guard let workspacePath else {
            actionFailure = Self.noWorkspace
            return
        }
        await control(runID, in: workspacePath) {
            try await client.resume(runID: runID, in: workspacePath)
        }
    }

    /// The list the label and the picker draw from, read when the drawer shows a workspace and
    /// again when the picker opens: `workflow list` reads every workflow file in the project, so
    /// it is not on the poll.
    func loadWorkflows(in workspacePath: WorkspacePath?) async {
        launchFailure = nil
        guard let workspacePath else {
            launchFailure = Self.noWorkspace
            return
        }
        // Only the latest load writes anything. The drawer's task cancels a load when the
        // workspace changes, and the replacement starts before the old one has unwound: its
        // flag, list and note belong to the new workspace.
        workflowLoads += 1
        let load = workflowLoads
        isLoadingWorkflows = true
        defer { if load == workflowLoads { isLoadingWorkflows = false } }
        do {
            let response = try await client.workflows(in: workspacePath)
            guard load == workflowLoads else { return }
            workflows = response.workflows
            workflowLoadErrors = response.errors
            // The note is about one workspace's list; another workspace's says nothing here.
            if workspacePath != workflowsWorkspace {
                workflowNote = nil
                workflowsWorkspace = workspacePath
            }
            seedWorkflow()
        } catch is CancellationError {
            // The drawer's task was cancelled (workspace switched, drawer hidden): nobody asked
            // for a launch, so nothing failed.
            return
        } catch {
            guard load == workflowLoads else { return }
            launchFailure = error.localizedDescription
        }
    }

    /// **A stored name this workspace does not have is not a choice here** (#528). The choice
    /// is one value for every workspace, so it can name a workflow from another project — the
    /// operator's did — and the label would then show something Send cannot launch. An empty
    /// list changes nothing: there is nothing better to put there.
    private func seedWorkflow() {
        let names = workflows.map(\.name)
        guard let first = names.first, !names.contains(config.workflow) else { return }
        if names.contains(Self.defaultWorkflow) {
            config.workflow = Self.defaultWorkflow
        } else {
            config.workflow = first
            workflowNote = "no \(Self.defaultWorkflow) here"
        }
    }

    /// The label, or `w` in the run list: the searchable list opens at once and is refreshed
    /// behind it, so a workflow file added since the drawer opened is in it.
    func openWorkflowPicker(in workspacePath: WorkspacePath?) async {
        isPickingWorkflow = true
        await loadWorkflows(in: workspacePath)
    }

    /// The operator's choice, which also retires the note about the default.
    func pick(_ workflow: String) {
        config.workflow = workflow
        workflowNote = nil
        isPickingWorkflow = false
    }

    /// The picker's rows for what is typed, filtered and ranked the way the ⌘K palette is.
    func workflows(matching query: String) -> [ArchonWorkflow] {
        FuzzyMatch.rank(workflows, by: query) { $0.name }
    }

    /// ⌥↑ / ⌥↓ in the composer: the previous or next workflow becomes what a launch runs. The list
    /// is loaded the first time it is asked for.
    func cycleWorkflow(by step: Int, in workspacePath: WorkspacePath?) async {
        if workflows.isEmpty { await loadWorkflows(in: workspacePath) }
        let names = workflows.map(\.name)
        guard !names.isEmpty else { return }
        let current = names.firstIndex(of: config.workflow) ?? (step > 0 ? -1 : 0)
        pick(names[(current + step + names.count) % names.count])
    }

    /// Enter in the field, or the send button. Everything except the message comes from the
    /// settings.
    func launch(in workspacePath: WorkspacePath?) async {
        guard !isLaunching else { return }
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflow = config.workflow.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspacePath else {
            launchFailure = Self.noWorkspace
            return
        }
        guard !workflow.isEmpty else {
            launchFailure = "Choose a workflow before launching."
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
