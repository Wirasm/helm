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
/// **A gate is the one thing here that is blocked on you, so it is the one thing above the
/// live work.** `paused` lost its number with the counts and never reached the inbox, and #147
/// had already taken the row Archon's approve/reject verbs hung on — two subtractions of the
/// same capability, put back as one line rather than two answers. The rail is now three lists:
/// gates, running, finished. A gate has verbs; the other two do not.
///
/// **Typed input retargets the one field rather than growing a second one.** The rail has
/// exactly one input and that stays true — arming a gate swaps what the composer is *for*, and
/// the launch draft is held aside untouched rather than overwritten, because losing a
/// half-written instruction to answer a gate is the version of this that gets sworn at. Which
/// decisions collect text is not a UI preference: Archon says which gates read it (see
/// `ArchonGate.needsText(for:)`), and the two that do would otherwise be answered blind.
///
/// **A gate is still invisible while the rail is hidden, and that is the rail's problem rather
/// than the gate's.** The inbox #153 shipped has exactly the same property, and the poll only
/// runs while `ArchonRailView` is on screen — so an always-visible gate means giving the poll a
/// lifetime independent of the view, which changes what helm costs when idle for every user
/// including those who never touch Archon. Solving it here would answer for gates a question
/// the whole rail asks, which is the second answer #150 warns against.
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
    /// Run id → the stage its subline names. Absent for a run whose detail call failed.
    @Published private(set) var stages: [String: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLaunching = false
    /// **The one piece of text here that is not in the rail's list, and it is deliberate.**
    /// Everything ambient was cut — no liveness word, no empty-state prose, no footer — but a
    /// send button that silently does nothing is a worse defect than a line of text, and this
    /// is the only place Archon's own reason for refusing a launch can be read.
    @Published private(set) var launchFailure: String?
    /// Why the last decision did not land. **Separate from `launchFailure`** because the two sit
    /// on different halves of the rail, and a rejected launch must not be cleared by a
    /// successful approve.
    @Published private(set) var actionFailure: String?
    /// The gate the composer is currently answering, if any. Nil is the launch composer.
    @Published private(set) var reply: ArchonGateReply?
    /// A set rather than a flag: two gates are independently answerable, and a spinner over the
    /// whole rail would say the wrong thing about the other one.
    @Published private(set) var busyRuns: Set<String> = []
    @Published private(set) var workflows: [ArchonWorkflow] = []
    @Published private(set) var workflowLoadErrors: [ArchonWorkflowLoadError] = []
    @Published private(set) var isLoadingWorkflows = false
    let worktrees: WorktreesRailModel

    private let client: any ArchonClient
    private let defaults: UserDefaults
    private let opener: ArchonRunOpener
    /// Not `@Published`: nothing renders the dismissals themselves, only their effect on
    /// `finished`, and publishing a store the view never reads would invalidate it for nothing.
    private var dismissals: ArchonInboxDismissals
    private var commands: Set<AnyCancellable> = []

    init(
        client: any ArchonClient = ArchonCLI(),
        worktreeClient: any WorktreeClient = WorktreeCLI(),
        defaults: UserDefaults = DefaultsDomain.store,
        opener: ArchonRunOpener = .live
    ) {
        self.client = client
        worktrees = WorktreesRailModel(worktreeClient: worktreeClient, archonClient: client)
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
        HelmCommand.publisher
            .filter { if case .toggleRail = $0 { true } else { false } }
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
            stages = [:]
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

    /// One extra `archon` per running run, per poll — issued concurrently, so they cost latency
    /// once rather than N times (measured: two calls in parallel finish in 0.59s, one alone in
    /// 0.56s). Only runs that have a line are asked about, so the cost is bounded by what is on
    /// screen, and in practice that is nought or one.
    private func refreshStages(in workspacePath: WorkspacePath) async {
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
    func loadWorkflows(in workspacePath: WorkspacePath?) async {
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
    func launch(in workspacePath: WorkspacePath?) async {
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
