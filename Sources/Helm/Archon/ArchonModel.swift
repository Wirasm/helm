import Combine
import Foundation

/// The Archon drawer's model (#382): what Archon is doing in the active workspace's project, and
/// the verbs the operator answers it with.
///
/// **Three lists, from two calls.** `gated` (paused runs, the only rows blocked on the
/// operator, so they come first), `running`, and `finished` (completed or failed runs he has
/// not cleared). `workflow runs --json` answers all three with each run's stage list; when any
/// run is live, `workflow status --json --verbose` adds the per-node fold its stage dots are
/// coloured from. A refresh is one or two `archon` processes whatever the number of runs. It
/// used to be one plus one `workflow get` per running run.
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
/// **One input with two jobs.** Arming a gate retargets the composer; the launch draft is held
/// aside, because losing a half-written instruction to answer a gate is the version of this
/// that gets sworn at. Which decisions collect text is Archon's rule
/// (`ArchonGate.needsText(for:)`), not a UI preference.
///
/// **Nothing polls while the drawer is hidden**, so a gate is only seen when the drawer is
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

    /// What the operator is typing **at a gate**, kept apart from `draft` on purpose: answering
    /// a gate must not cost a half-written launch instruction, and one string for both is
    /// exactly how it would.
    @Published var replyText = "" { didSet { actionFailure = nil } }

    /// The paused runs, above the running ones. Not all of them are actionable — see
    /// `ArchonGate.isAwaitingDecision` — but every one of them is a run with no other surface.
    @Published private(set) var gated: [ArchonRun] = []
    /// The runs that get a live line. Only `running` — see the note on the type.
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
    /// Failed `runs` calls in a row, so one hiccup can be told from a failure that persists.
    private var failedPolls = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLaunching = false
    /// **The one piece of text here that is not in the drawer's list, and it is deliberate.**
    /// Everything ambient was cut — no liveness word, no empty-state prose, no footer — but a
    /// send button that silently does nothing is a worse defect than a line of text, and this
    /// is the only place Archon's own reason for refusing a launch can be read.
    @Published private(set) var launchFailure: String?
    /// Why the last decision did not land. **Separate from `launchFailure`** because a rejected
    /// launch must not be cleared by a successful approve.
    @Published private(set) var actionFailure: String?
    /// The gate the composer is currently answering, if any. Nil is the launch composer.
    @Published private(set) var reply: ArchonGateReply?
    /// A set rather than a flag: two gates are independently answerable, and a spinner over the
    /// whole rail would say the wrong thing about the other one.
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
            gated = []
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
            let response = try await client.runs(in: workspacePath)
            failedPolls = 0
            refreshFailure = nil
            apply(response, in: workspacePath)
            await refreshLiveNodes(in: workspacePath)
        } catch is CancellationError {
            return
        } catch {
            // The last known runs are always kept: blanking the drawer on a hiccup would make
            // the rows flap. One failure after a good poll says nothing either. With no rows
            // to keep, or a second failure in a row, it is not a hiccup and the reason shows.
            failedPolls += 1
            if failedPolls > 1 || (gated.isEmpty && running.isEmpty && finished.isEmpty) {
                refreshFailure =
                    "Could not list Archon runs in \(workspacePath.value): "
                    + error.localizedDescription
            }
        }
    }

    /// The two published lists, derived from Archon's last answer.
    ///
    /// **Both come from `runs`, and `counts` is now ignored entirely.** They were always about
    /// different sets — `counts` spans the project (or the machine, under `scopeFallback`)
    /// while `runs` is the newest twenty — and the arithmetic that reconciled them existed only
    /// to keep a tally honest. There is no tally left to keep honest.
    private func apply(_ response: ArchonRunsResponse, in workspacePath: WorkspacePath) {
        gated = response.runs.filter(\.isPaused)
        running = response.runs.filter(\.isRunning)
        finished =
            response.runs
            .filter { $0.isFinished && !dismissals.contains($0.id, in: workspacePath) }
            .sorted { left, right in
                // `completed_at` is what the operator means by "the last one to finish", and a
                // run missing it sorts last rather than crashing the comparison.
                (left.completedAt ?? .distantPast) > (right.completedAt ?? .distantPast)
            }
        // A gate answered from anywhere — Archon's own UI, a terminal, another helm — takes the
        // composer back with it. Leaving it armed would offer Send against a decision already
        // made.
        //
        // **And it says so, because the silent version of this is worse than it looks.** The
        // field would revert to the launch draft under the operator's hands mid-sentence, and
        // the Enter they were about to press would launch a workflow instead of answering a
        // gate. `busyRuns` marks the decision helm is itself making, which is the one case the
        // composer is *expected* to lose and needs no sentence.
        if let reply, !gated.contains(where: { $0.id == reply.runID && $0.isAwaitingDecision }) {
            let ours = busyRuns.contains(reply.runID)
            disarm()
            if !ours {
                actionFailure = "That gate was answered elsewhere. Nothing was sent."
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

    // MARK: - Answering a gate

    /// A verb was pressed on a gate: either send it now, or point the composer at it first.
    ///
    /// **The branch is read from the gate, not chosen by taste.** `needsText(for:)` is true for
    /// exactly the decisions whose text Archon acts on — a rejection's rework prompt, a
    /// `captureResponse` node's own output, an interactive loop's iterate-or-finalize — so
    /// sending those blind would quietly pick an answer on the operator's behalf. Everywhere
    /// else the comment reaches an audit event nobody reads, and asking for one would be a
    /// second click that buys nothing.
    func choose(
        _ decision: ArchonGateDecision, on run: ArchonRun, in workspacePath: WorkspacePath?
    ) async {
        guard let gate = run.gate, gate.isAwaitingDecision else { return }
        guard !busyRuns.contains(run.id) else { return }
        if gate.needsText(for: decision) {
            arm(decision, on: run)
            return
        }
        await decide(decision, text: nil, on: run, in: workspacePath)
    }

    /// Point the composer at a gate. The launch draft is untouched — the field simply binds to
    /// the other string until this is sent or cancelled.
    func arm(_ decision: ArchonGateDecision, on run: ArchonRun) {
        reply = ArchonGateReply(runID: run.id, decision: decision, workflowName: run.workflowName)
        replyText = ""
        actionFailure = nil
    }

    /// Give the composer back to launching. Nothing is sent.
    func disarm() {
        reply = nil
        replyText = ""
    }

    /// Enter in an armed composer, or its send button.
    ///
    /// **An empty answer is allowed through.** Both flags are optional to Archon, and for an
    /// interactive loop "nothing to add" is a real decision — it is what finalizes the loop
    /// rather than running another iteration. Refusing to send it would make the one gate that
    /// distinguishes them unanswerable in the finalize direction.
    func sendReply(in workspacePath: WorkspacePath?) async {
        guard let reply else { return }
        // The run going missing between arming and sending is the same race `apply` handles,
        // caught here for the frame in which the press wins. Reported rather than dropped: a
        // Send that does nothing at all is the failure this whole rail keeps arguing against.
        guard let run = gated.first(where: { $0.id == reply.runID }) else {
            disarm()
            actionFailure = "That gate is gone. Nothing was sent."
            return
        }
        await decide(reply.decision, text: replyText, on: run, in: workspacePath)
    }

    /// One of Archon's gate verbs, run against one run, and then the resume it leaves behind.
    ///
    /// **`ok` is checked, not the exit status** — the standing rule for every `--json` verb:
    /// they catch their own failures, print `{"ok": false, …}` and exit zero, so "the process
    /// succeeded" and "the gate was answered" are different facts.
    ///
    /// **A decision that leaves the run parked is finished by resuming it here.** Archon records
    /// the decision in `--json` mode without executing, because executing streams the workflow's
    /// output over the JSON contract; its own interactive form resumes immediately afterwards,
    /// and an Approve that left the run sitting exactly where it was would be a control that
    /// lies by omission. **The resume is reported separately when it fails**, because by then the
    /// approval is already recorded and saying "approve failed" would be a third wrong answer.
    private func decide(
        _ decision: ArchonGateDecision, text: String?, on run: ArchonRun,
        in workspacePath: WorkspacePath?
    ) async {
        guard let workspacePath else {
            actionFailure = Self.noWorkspace
            return
        }
        guard !busyRuns.contains(run.id) else { return }
        busyRuns.insert(run.id)
        actionFailure = nil
        defer { busyRuns.remove(run.id) }

        // **The failure is carried, not assigned as it is found, and the order is the point.**
        // `disarm()` and the refresh below both write state whose observers clear
        // `actionFailure` — so a sentence set before them is a sentence the operator never
        // reads. It is published last, when nothing is left to wipe it.
        var failure: String?
        do {
            let acknowledgement = try await client.decide(
                decision, text: text, on: run.id, in: workspacePath)
            if acknowledgement.ok {
                disarm()
                if acknowledgement.leavesRunResumable {
                    failure = await resumeFailure(for: run, after: decision)
                }
            } else {
                failure =
                    "Archon refused to \(decision.verb) this run: "
                    + (acknowledgement.error ?? "no reason given")
            }
        } catch {
            failure = error.localizedDescription
        }
        // Refreshed even on a refusal, and especially then: the commonest reason Archon refuses
        // is that the gate was already answered somewhere else, so the row helm is showing is
        // the stale thing that produced the click.
        await refresh(in: workspacePath)
        actionFailure = failure
    }

    /// nil when the run really did restart.
    private func resumeFailure(
        for run: ArchonRun, after decision: ArchonGateDecision
    ) async -> String? {
        let recorded = decision.verb.capitalized
        do {
            let resumed = try await client.resume(run)
            guard resumed.ok, resumed.detached else {
                return "\(recorded) recorded, but Archon did not restart the run. "
                    + "Resume it from a terminal."
            }
            return nil
        } catch {
            return "\(recorded) recorded, but the run did not restart: "
                + error.localizedDescription
        }
    }

    /// The per-node fold for every live run, from one `workflow status --verbose`. Skipped when
    /// nothing is live, which is the common case, so an idle refresh is one process.
    private func refreshLiveNodes(in workspacePath: WorkspacePath) async {
        guard !gated.isEmpty || !running.isEmpty else {
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

    /// Stop a running run. Reported like a gate decision, on the same line.
    func cancel(_ run: ArchonRun, in workspacePath: WorkspacePath?) async {
        guard let workspacePath else {
            actionFailure = Self.noWorkspace
            return
        }
        guard run.isRunning, !busyRuns.contains(run.id) else { return }
        busyRuns.insert(run.id)
        actionFailure = nil
        defer { busyRuns.remove(run.id) }
        var failure: String?
        do {
            let acknowledgement = try await client.cancel(runID: run.id, in: workspacePath)
            if !acknowledgement.ok {
                failure =
                    "Archon refused to cancel this run: "
                    + (acknowledgement.error ?? "no reason given")
            }
        } catch {
            failure = error.localizedDescription
        }
        await refresh(in: workspacePath)
        actionFailure = failure
    }

    /// Resume a failed or paused run from its completed nodes.
    func resume(_ run: ArchonRun, in workspacePath: WorkspacePath?) async {
        guard let workspacePath else {
            actionFailure = Self.noWorkspace
            return
        }
        guard run.status == ArchonRunStatus.failed || run.isPaused,
            !busyRuns.contains(run.id)
        else { return }
        busyRuns.insert(run.id)
        actionFailure = nil
        defer { busyRuns.remove(run.id) }
        let failure: String?
        do {
            let resumed = try await client.resume(run)
            failure =
                resumed.ok && resumed.detached ? nil : "Archon did not restart the run."
        } catch {
            failure = error.localizedDescription
        }
        await refresh(in: workspacePath)
        actionFailure = failure
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
