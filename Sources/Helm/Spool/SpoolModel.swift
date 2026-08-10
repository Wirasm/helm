import Foundation
import HelmWire

/// What helm does with an accepted request, as a seam.
///
/// **The whole point of the seam is that the watcher half is reachable from `swift test`.**
/// #54 asks for it in as many words, and three defects in two days came from logic trapped in
/// a `View`. Everything on the other side of this protocol needs a window, a ghostty surface
/// and a real pty; everything on this side — claiming, refusing, timing out, resolving a
/// handle, writing a result — does not, and is tested without any of them.
@MainActor
protocol SpoolSpawning: AnyObject {
    /// Open a terminal running a login shell in `cwd`, call the pane `named`, and return the
    /// pane's id. Synchronous: the session exists the moment it is made, long before its surface
    /// attaches.
    ///
    /// **The name is computed on *this* side of the seam** (`PaneName.derived(for:)`, in
    /// `HelmWire`) and handed over, rather than derived from `cwd` over there — so what a spawned
    /// pane ends up called is a rule `swift test` can read with no bench, no surface and no pty,
    /// which is the trade this whole protocol exists to make.
    func openTerminal(cwd: String, named: PaneName) -> Result<UUID, SpoolRefusal>
    /// The pty's foreground pid — nil until the surface exists and has a process under it.
    func foregroundPid(of terminal: UUID) -> pid_t?
    /// Write bytes into that pty. Not a keystroke: it goes to *this* surface directly, so it
    /// cannot land in whatever pane happens to hold the keyboard (#96).
    func send(_ line: String, to terminal: UUID)
}

/// helm drawing its own window, as a seam — the same trade `SpoolSpawning` makes.
///
/// Everything on the far side needs a real `NSWindow` with a laid-out view tree; the deciding,
/// refusing and result-writing on this side does not, and is reached from `swift test` with a
/// capturer that has no window at all. That is also how the *refusal* paths get exercised,
/// which are the ones a live run is least likely to hit by accident.
@MainActor
protocol SpoolCapturing: AnyObject {
    /// Draw helm's own window into a PNG at `path`, or say why not.
    ///
    /// Synchronous, unlike a spawn: drawing has no second party to wait for, so there is one
    /// write to the result file rather than two.
    func capture(to path: String, window: String?) -> Result<CaptureReport, SpoolRefusal>
}

/// Taking a pane off the bench, as a seam — the inverse of `SpoolSpawning` and the same trade.
///
/// **Two calls rather than one, and the split is where the design lives.** `pane` reports what
/// helm can see; `close` does the deed. Everything between them — the operator's focus, live
/// work, `force` — is `SpoolClosePolicy`'s and is decided on this side of the protocol, so
/// every rule #176 argues for is reachable from `swift test` with no bench, no surface and no
/// pty. An adapter that decided for itself would put the one part worth testing on the far
/// side of the one seam a test cannot cross.
@MainActor
protocol SpoolClosing: AnyObject {
    /// What helm can see about one pane right now, or nil when no pane has that id.
    func pane(_ id: UUID) -> SpoolPaneState?
    /// Take it off the bench and drop its pty. Reports whether the pane is actually gone —
    /// the bench refuses its own last pane (`Workbench.canClose`), and a caller told "closed"
    /// about a pane that is still there is the silence this ladder exists to remove.
    func close(_ id: UUID) -> Bool
}

/// Bringing a pane forward, as a seam — `SpoolClosing`'s twin, and the same trade (#284).
///
/// **It repeats `pane(_:)` rather than inheriting it, and one adapter satisfies both.**
/// `WorkbenchSpoolPanes` is the only implementation of either, so a shared base protocol would
/// buy a third name for a lookup that has exactly one caller per request kind — and the fake in
/// `SpoolModelTests` would still have to implement it. What matters is that a select is judged
/// against **the same value** a close is: `SpoolPaneState` is read once per request and
/// `SpoolSelectPolicy` decides on this side of the protocol, with no bench, no surface and no pty.
@MainActor
protocol SpoolSelecting: AnyObject {
    /// What helm can see about one pane right now, or nil when no pane has that id.
    func pane(_ id: UUID) -> SpoolPaneState?
    /// Make it the pane its slot is showing, **without moving the keyboard**, and report what the
    /// bench then looked like. The failure is helm having no bench to show anything on; every
    /// question about whether it *may* be shown was already answered by `SpoolSelectPolicy`.
    func select(_ id: UUID) -> Result<SelectReport, SpoolRefusal>
}

/// Calling a pane something, as a seam — `SpoolClosing`'s and `SpoolSelecting`'s third sibling,
/// and the same trade (#313).
///
/// **It repeats `pane(_:)` for the reason `SpoolSelecting` does, and the reason has not changed
/// with a third caller.** `WorkbenchSpoolPanes` is still the only implementation of any of them,
/// so a shared base protocol would buy a third name for a lookup with one caller per kind, and
/// every fake in `SpoolModelTests` would still have to implement it. What matters is that a name
/// is judged against **the same value** a close and a select are: `SpoolPaneState` is read once
/// per request, and `SpoolNamePolicy` decides on this side of the protocol with no bench at all.
@MainActor
protocol SpoolNaming: AnyObject {
    /// What helm can see about one pane right now, or nil when no pane has that id.
    func pane(_ id: UUID) -> SpoolPaneState?
    /// Call it that, and report what it was called before and what it is called now — **read back
    /// off the bench**, not echoed. The failure is helm having no bench to name a pane on; whether
    /// it *may* be renamed was already answered by `SpoolNamePolicy`.
    func name(_ id: UUID, to name: PaneName) -> Result<NameReport, SpoolRefusal>
}

/// Driving the bench, as a seam — the same trade `SpoolSpawning`, `SpoolCapturing` and
/// `SpoolClosing` all make (#269).
///
/// **One call, and everything worth deciding is already decided before it.** Which commands an
/// agent may send is `SpoolCommandPolicy`'s, in `HelmWire`, reachable from `swift test` with no
/// bench at all; which non-seizing twin an allowed command routes to is
/// `WorkbenchSpoolCommander`'s, on the far side, because it is the one thing that genuinely
/// needs a live `WorkbenchModel`. An adapter that decided *whether* would put the reviewable
/// half where a test cannot reach it, which is exactly what `SpoolClosing`'s split avoids.
@MainActor
protocol SpoolCommanding: AnyObject {
    /// Carry out a command helm has already agreed an agent may send, and report what it did.
    ///
    /// Synchronous, like a capture and a close: a command is applied to the bench value and
    /// there is no second party to wait for, so one write to the result rather than two.
    func run(_ command: HelmCommandName) -> Result<CommandReport, SpoolRefusal>
}

/// The spool: helm's one push channel, and the rung of #51 that works with the screen locked.
///
/// **This is a deliberate reversal, and it is recorded as one.** #33 ruled *"there is no
/// control channel, and building one would be the mistake"* — a pane appearing unbidden is
/// helm rearranging the bench on an agent's word. That rule's own justification was *"it's not
/// helm's job to decide for me how to organize"*, and here the operator is explicitly asking
/// for agents to spawn agents, so the justification does not apply. The ruling stands
/// everywhere else: a ⌘-clicked link is still an offer, and nothing else in helm pushes.
///
/// **helm grows a watcher, not an API.** Nothing here is callable. A file appears, helm acts,
/// helm writes a file back.
@MainActor
final class SpoolModel: ObservableObject {
    /// How often a pid is re-read while waiting for something to happen to it. A pid has no
    /// event source, so this genuinely is a poll — unlike the directory, which is watched.
    static let pollInterval: Duration = .milliseconds(200)

    private let directory: SpoolDirectory
    private let mailRoot: URL
    /// Claude Code's session registry, which is how a pid becomes a session id and a session id
    /// becomes a mailbox (#247). Injectable for the same reason `mailRoot` is: a test that reads
    /// the operator's live `~/.claude/sessions` is testing the machine, not the rule.
    private let registryRoot: URL
    private let isOff: Bool
    /// How long a freshly created terminal has to produce a login shell. Generous, because a
    /// deadline that can expire before the child is scheduled is the exact flake shape #157
    /// and PR #155 both had.
    private let shellDeadline: Duration
    /// How long the agent has to claim a mailbox. Longer still: this covers a whole agent
    /// start-up plus its `SessionStart` hook.
    private let claimDeadline: Duration

    /// Held **strongly**, and that is deliberate. It was `weak` first, and the whole feature
    /// failed on the first live request with `failed: helm has no workbench to open a terminal
    /// in` — nothing else retained the adapter `RootView` builds, so it was gone before a
    /// request ever arrived. The spawner references nothing here, so there is no cycle to
    /// avoid; a weak reference bought nothing and cost the capability.
    private var spawner: (any SpoolSpawning)?
    /// Held strongly for the same reason, and it is the same failure if it is not: an adapter
    /// `RootView` builds inline is retained by nothing else, so a weak reference would be gone
    /// before the first request and every capture would answer "helm has no window to draw".
    private var capturer: (any SpoolCapturing)?
    /// Held strongly for the same reason as the two above, and it is the same failure if it is
    /// not: an adapter `RootView` builds inline is retained by nothing else, so a weak
    /// reference would be gone before the first request and every close would answer "helm has
    /// no bench".
    private var closer: (any SpoolClosing)?
    /// Held strongly for the same reason as the three above, and it is the same failure if it
    /// is not: an adapter `RootView` builds inline is retained by nothing else, so a weak
    /// reference would be gone before the first request and every command would answer "helm
    /// has no bench".
    private var commander: (any SpoolCommanding)?
    /// Held strongly for the same reason as the four above, and it is the same failure if it is
    /// not: an adapter `RootView` builds inline is retained by nothing else, so a weak reference
    /// would be gone before the first request and every select would answer "helm has no bench".
    private var selector: (any SpoolSelecting)?
    /// Held strongly for the same reason as the five above, and it is the same failure if it is
    /// not: an adapter `RootView` builds inline is retained by nothing else, so a weak reference
    /// would be gone before the first request and every name would answer "helm has no bench".
    private var namer: (any SpoolNaming)?
    private var watcher: SpoolWatcher?

    /// Requests acted on in this process, by result id — so a second window's `drain` and this
    /// one's backstop cannot both answer the same request. Between *processes* the rename is
    /// what decides; this is the cheaper in-process half of the same rule.
    private var handled: Set<String> = []

    init(
        directory: SpoolDirectory = .resolve(),
        mailRoot: URL = MailboxDirectory.resolve(),
        registryRoot: URL = AgentRegistry.defaultRoot,
        isOff: Bool = SpoolDirectory.isOff(),
        shellDeadline: Duration = .seconds(20),
        claimDeadline: Duration = .seconds(90)
    ) {
        self.directory = directory
        self.mailRoot = mailRoot
        self.registryRoot = registryRoot
        self.isOff = isOff
        self.shellDeadline = shellDeadline
        self.claimDeadline = claimDeadline
    }

    func attach(spawner: any SpoolSpawning) {
        self.spawner = spawner
    }

    func attach(capturer: any SpoolCapturing) {
        self.capturer = capturer
    }

    func attach(closer: any SpoolClosing) {
        self.closer = closer
    }

    func attach(commander: any SpoolCommanding) {
        self.commander = commander
    }

    func attach(selector: any SpoolSelecting) {
        self.selector = selector
    }

    func attach(namer: any SpoolNaming) {
        self.namer = namer
    }

    /// Begin watching. Idempotent, and a no-op under `HELM_SPOOL_OFF`.
    ///
    /// **The off switch is the negative control**, not a preference: a probe that has not been
    /// shown to fail proves nothing, so "with the watcher disabled, a request produces no
    /// terminal and no result" is the run that gives every other claim here its meaning.
    func start() {
        guard !isOff else {
            NSLog(
                "helm: %@ is set — the spool is not watched, and requests will pile up unread",
                SpoolDirectory.offVariable)
            return
        }
        guard watcher == nil else { return }
        do {
            try directory.prepare()
        } catch {
            NSLog(
                "helm: could not prepare the spool at %@: %@ — nothing will be watched",
                directory.root.path, String(describing: error))
            return
        }
        answerAbandoned()
        let watcher = SpoolWatcher(directory: directory.root) { [weak self] in self?.drain() }
        self.watcher = watcher
        watcher.start()
        NSLog("helm: watching the spool at %@", directory.root.path)
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// A request claimed by a previous run that never got an answer, because helm stopped
    /// between the rename and the result.
    ///
    /// **It is answered, not re-run.** Re-running is the double-open #54 forbids — "a restart
    /// mid-spawn must not double-open" — and it is the one failure mode a claim-by-rename
    /// cannot see, since from the outside a claimed file looks exactly like one being worked
    /// on. So the caller is told why nothing happened, which beats it waiting on a file that
    /// was never coming.
    private func answerAbandoned() {
        for id in directory.abandoned() where !handled.contains(id.value) {
            handled.insert(id.value)
            directory.write(
                SpoolResult(
                    id: id, status: .abandoned,
                    reason:
                        "helm stopped while this request was in flight. It was NOT re-run: a "
                        + "request is acted on at most once, so a restart must not double-open. "
                        + "Send it again if you still want it."))
            NSLog("helm: spool request %@ was abandoned by a restart", id.value)
        }
    }

    /// One pass over the spool: claim what is there, and answer everything claimed.
    ///
    /// Every path writes a result. A refused or malformed request that writes nothing is
    /// indistinguishable from helm not running, which is the silence this ladder exists to
    /// remove.
    func drain() {
        for url in directory.pending() {
            guard let claimed = directory.claim(url) else { continue }
            let fallbackID = claimed.deletingPathExtension().lastPathComponent
            guard let request = directory.request(at: claimed) else {
                // **The shapes come from the request types, not from a sentence here.** This
                // used to restate every kind's fields by hand, one module away from the structs
                // that define them, and nothing tied the two together — so a kind added without
                // touching this line would answer a caller with a description of the four that
                // came before it. See `SpoolRequest.wireShapes`.
                refuse(
                    id: fallbackID,
                    reason: "the request file is not readable JSON of the form "
                        + "{\"id\",\"kind\",…} — " + SpoolRequest.wireShapes)
                continue
            }
            guard !handled.contains(request.id) else { continue }
            handled.insert(request.id)
            switch SpoolPolicy.accept(
                request, captures: directory.captures, isDirectory: Self.isDirectory)
            {
            case .failure(let refusal):
                refuse(id: request.id, reason: refusal.reason)
            case .success(.spawn(let accepted)):
                Task { await self.act(on: accepted) }
            case .success(.capture(let accepted)):
                act(on: accepted)
            case .success(.close(let accepted)):
                act(on: accepted)
            case .success(.command(let accepted)):
                act(on: accepted)
            case .success(.select(let accepted)):
                act(on: accepted)
            case .success(.name(let accepted)):
                act(on: accepted)
            }
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        return exists && directory.boolValue
    }

    /// **Still a second guard, and still not a second spelling (#260).** It takes a raw `String`
    /// because it has to, and both of its callers are in `drain`, before anything has been
    /// validated: one passes `fallbackID`, derived from the *filename* when the JSON would not
    /// parse and `SpoolPolicy.accept` therefore never ran, and the other passes a decoded
    /// `SpoolRequest.id` that `accept` has just refused. What changed is that it no longer
    /// re-applies a shared regex by hand — it asks `RequestID`, which is the same question
    /// `accept` asks, expressed once in the type instead of twice at two call sites.
    private func refuse(id raw: String, reason: String) {
        // An id that is not a filename cannot name a result file, so there is nowhere to put
        // the answer. The log is all that is left, and it says so rather than pretending.
        //
        // `raw` rather than shadowing `id`, which is the idiom `SpoolDirectory.abandoned()` uses
        // for the identical guard: shadowing is valid here — the `else` branch still sees the
        // `String` — but only to a reader who knows that rule, and this line has to print the
        // string the caller sent rather than anything derived from it.
        guard let id = RequestID(validating: raw) else {
            NSLog(
                "helm: spool request refused and UNANSWERABLE (id %@ is not a filename): %@",
                raw, reason)
            return
        }
        refuse(id: id, reason: reason)
    }

    /// The same refusal for a request that **already passed `SpoolPolicy.accept`** and is being
    /// turned down by a policy afterwards — a close on the operator's own pane, a select on the
    /// focused slot, a name somebody already chose.
    ///
    /// **It carries no guard, and the overload is how that becomes a fact rather than a claim
    /// (#260).** These ids came out of an `Accepted*` request, so they are `RequestID`s and there
    /// is nothing left to check; the guarded route above exists for the two callers that genuinely
    /// have a raw string. Which of the two a call site gets is decided by the compiler from the
    /// type it is holding, instead of by a reader working out whether a check upstream already ran.
    private func refuse(id: RequestID, reason: String) {
        directory.write(SpoolResult(id: id, status: .refused, reason: reason))
        NSLog("helm: spool request %@ refused — %@", id.value, reason)
    }

    /// Draw helm's own window, then say what is in the PNG — **including what is not**.
    ///
    /// **Synchronous, and nothing here waits on a permission.** Screen Recording is a TCC grant
    /// that cannot be granted from code and attaches to the invoking context, which is why
    /// `winshot` fails for an agent even where the operator has granted it; helm rendering its
    /// own view hierarchy is drawing, and is gated by none of that (#174, `WindowCapture`).
    private func act(on request: AcceptedCaptureRequest) {
        guard let capturer else {
            answer(
                request.id, .failed,
                reason: "helm has no window to draw. It is running, and it answered this "
                    + "request — so the capturer was never attached, which is a helm defect "
                    + "rather than anything the caller can fix.")
            return
        }
        switch capturer.capture(to: request.path, window: request.window) {
        case .success(let report):
            answer(request.id, .captured, capture: report)
        case .failure(let refusal):
            answer(request.id, .failed, reason: refusal.reason)
        }
    }

    /// Take a pane off the bench, or say why not (#176).
    ///
    /// **Synchronous, like a capture and unlike a spawn.** There is no second party: the pane
    /// is gone the moment the bench lets go of it, so there is nothing outstanding to wait for
    /// and one write rather than two.
    ///
    /// **Every path here writes a result, and the refusals are `refused` rather than
    /// `failed`.** They are decisions, not breakages — the caller can read the reason and do
    /// something about it (wait for the operator to move, send `force`, use the right uuid),
    /// which is a different thing from helm being unable to act. `failed` is kept for the one
    /// case that genuinely is helm's own defect.
    private func act(on request: AcceptedCloseRequest) {
        guard let closer else {
            answer(
                request.id, .failed,
                reason: "helm has no bench to close a pane on. It is running, and it answered "
                    + "this request — so the closer was never attached, which is a helm defect "
                    + "rather than anything the caller can fix.")
            return
        }
        // `SpoolClosing` is the app-side seam (`SpoolSpawning`'s twin) and stays `UUID`-typed —
        // `TerminalID` is the wire's currency, not the live bench's, and `WorkbenchSpoolPanes`
        // is out of scope for this change. `.uuid` is the one place that boundary is crossed.
        let pane = closer.pane(request.terminal.uuid)
        if let refusal = SpoolClosePolicy.refusal(for: request, pane: pane) {
            refuse(id: request.id, reason: refusal.reason)
            return
        }
        guard closer.close(request.terminal.uuid) else {
            refuse(
                id: request.id,
                reason: "helm's bench would not let pane \(request.terminal.uuidString) go. It "
                    + "is the last pane there is, and a helm with nothing in it is not a state "
                    + "worth being able to reach (Workbench.canClose)")
            return
        }
        answer(
            request.id, .closed, terminalId: request.terminal, pid: pane?.foreground)
    }

    /// Bring a pane forward, or say why not (#284).
    ///
    /// **Synchronous, and one write** — a select is applied to the bench value and there is no
    /// second party to wait for, exactly as a close and a capture are.
    ///
    /// **The refusals are `refused` rather than `failed`, and the split is `act(on:
    /// AcceptedCloseRequest)`'s.** A pane in the operator's own slot and a uuid helm holds no
    /// pane for are decisions the caller can read and do something about; helm having no bench at
    /// all is helm's own state, which is `failed`.
    private func act(on request: AcceptedSelectRequest) {
        guard let selector else {
            answer(
                request.id, .failed,
                reason: "helm has no bench to show a pane on. It is running, and it answered "
                    + "this request — so the selector was never attached, which is a helm defect "
                    + "rather than anything the caller can fix.")
            return
        }
        // `SpoolSelecting` is the app-side seam and stays `UUID`-typed, exactly as `SpoolClosing`
        // does: `TerminalID` is the wire's currency, not the live bench's. `.uuid` is the one
        // place that boundary is crossed.
        let pane = selector.pane(request.pane.uuid)
        if let refusal = SpoolSelectPolicy.refusal(for: request, pane: pane) {
            refuse(id: request.id, reason: refusal.reason)
            return
        }
        switch selector.select(request.pane.uuid) {
        case .success(let report):
            guard report.isVisible else {
                // The bench was asked and the pane is still not the one its slot shows. Nothing
                // known makes this reachable — which is why it is reported rather than assumed
                // away: a `selected` result about a pane nobody can see is the lie #284 is about.
                refuse(
                    id: request.id,
                    reason: "helm's bench did not make pane \(request.pane.uuidString) its "
                        + "slot's selection, so it is still not visible. Nothing was moved and "
                        + "nothing was lost; read ~/.helm/bench/snapshot.json to see where the "
                        + "pane actually is")
                return
            }
            answer(request.id, .selected, terminalId: request.pane, select: report)
        case .failure(let refusal):
            answer(request.id, .failed, reason: refusal.reason)
        }
    }

    /// Call a pane something, or say why not (#313).
    ///
    /// **Synchronous, and one write** — naming is applied to the bench value and there is no
    /// second party to wait for, exactly as a close, a capture and a select are.
    ///
    /// **The refusals are `refused` rather than `failed`, and the split is the other two addressed
    /// verbs'.** A pane somebody has already named and a uuid helm holds no pane for are decisions
    /// the caller can read and do something about; helm having no bench at all is helm's own
    /// state, which is `failed`.
    ///
    /// **`.chosen`, always — an agent's name is somebody's choice by definition.** `.derived` is
    /// what helm gives a pane it opened for an agent, and it exists precisely so that the agent's
    /// own first naming is *not* treated as a rename. A request that produced a `.derived` name
    /// would make every pane re-namable for ever and the ownership rule vacuous.
    private func act(on request: AcceptedNameRequest) {
        guard let namer else {
            answer(
                request.id, .failed,
                reason: "helm has no bench to name a pane on. It is running, and it answered "
                    + "this request — so the namer was never attached, which is a helm defect "
                    + "rather than anything the caller can fix.")
            return
        }
        // `SpoolNaming` is the app-side seam and stays `UUID`-typed, exactly as `SpoolClosing` and
        // `SpoolSelecting` do: `TerminalID` is the wire's currency, not the live bench's.
        let pane = namer.pane(request.pane.uuid)
        if let refusal = SpoolNamePolicy.refusal(for: request, pane: pane) {
            refuse(id: request.id, reason: refusal.reason)
            return
        }
        switch namer.name(request.pane.uuid, to: .chosen(request.name)) {
        case .success(let report):
            answer(request.id, .named, terminalId: request.pane, name: report)
        case .failure(let refusal):
            answer(request.id, .failed, reason: refusal.reason)
        }
    }

    /// Drive the bench with one of helm's own commands, and say what it did (#269).
    ///
    /// **Whether this command may be sent at all was settled before we got here.**
    /// `SpoolPolicy.accept` runs `SpoolCommandPolicy.verdict`, so an `AcceptedCommandRequest`
    /// exists only for a command an agent is allowed to send — the same "answered by the
    /// compiler rather than by reading upwards" shape `SpoolWork`'s own header describes.
    /// Everything left here is helm being unable to act, which is `failed` rather than
    /// `refused`.
    private func act(on request: AcceptedCommandRequest) {
        guard let commander else {
            answer(
                request.id, .failed,
                reason: "helm has no bench to run a command on. It is running, and it answered "
                    + "this request — so the commander was never attached, which is a helm "
                    + "defect rather than anything the caller can fix.")
            return
        }
        switch commander.run(request.command) {
        case .success(let report):
            // `terminalId` carries the new pane as well as `command.paneCreated`, so the field
            // a caller already reads after a spawn means the same thing after a command and
            // `helm-close <terminalId>` is the next move with no lookup.
            answer(
                request.id, .ran, terminalId: report.paneCreated, command: report)
        case .failure(let refusal):
            answer(request.id, .failed, reason: refusal.reason)
        }
    }

    /// Start the agent, then say what was started and how to reach it.
    private func act(on request: AcceptedSpawnRequest) async {
        guard let spawner else {
            answer(request.id, .failed, reason: "helm has no workbench to open a terminal in")
            return
        }
        var promptPath: String?
        if let prompt = request.prompt {
            // Before the terminal, so a write failure costs nothing rather than leaving a
            // stray shell behind.
            guard let staged = directory.stagePrompt(prompt, for: request.id) else {
                answer(request.id, .failed, reason: "helm could not stage the prompt on disk")
                return
            }
            promptPath = staged
        }

        let terminal: UUID
        // **The fix for #313's concrete trigger, and it needs no wire format at all**: helm wrote
        // this request, so it already knows which agent is starting and where. `.derived` rather
        // than `.chosen`, deliberately — nobody picked these words, so the agent's own first
        // `helm-name` replaces them without having to claim the operator asked
        // (`SpoolNamePolicy`).
        switch spawner.openTerminal(cwd: request.cwd, named: .derived(for: request)) {
        case .failure(let refusal):
            answer(request.id, .failed, reason: refusal.reason)
            return
        case .success(let id):
            terminal = id
        }

        // **Waited on, never slept for.** A login shell exists exactly when the pty has a
        // foreground process, and that is observable — so this is the pane's own answer to
        // "am I ready", not a guess at how long a surface takes to attach.
        guard
            let shell = await poll(
                until: shellDeadline, for: { spawner.foregroundPid(of: terminal) })
        else {
            answer(
                request.id, .failed, terminalId: TerminalID(terminal),
                reason:
                    "a terminal was opened in helm but its shell never started within "
                    + "\(shellDeadline). Nothing was sent to it; it is sitting at an empty prompt.")
            return
        }

        // The line, not the line plus a Return: how a line is *submitted* is the adapter's
        // business, and it is not one write (see `WorkbenchSpoolSpawner.send`).
        spawner.send(SpoolLaunchLine.compose(request, promptPath: promptPath), to: terminal)
        answer(request.id, .started, terminalId: TerminalID(terminal))

        // **One wait with one budget, for two observables.** The pty's foreground pid moving
        // off the login shell is the pty saying the line actually ran; the mailbox appearing
        // is the agent saying it can be addressed. Waiting for them in sequence would spend
        // the deadline twice and make the worst case a caller sees twice as long as the number
        // this file names.
        let resolved = await poll(
            until: claimDeadline,
            for: { [mailRoot, registryRoot] () -> (agent: pid_t?, owner: MailboxOwner)? in
                let foreground = spawner.foregroundPid(of: terminal)
                // **Both halves are re-read on every attempt, and that is the point.** The
                // mailbox is written by the agent's `SessionStart` hook and its registry row by
                // the agent itself, so both appear *during* this poll — a book built once
                // before the loop would be waiting for something it could never see.
                let book = AddressBook(
                    owners: MailboxDirectory.owners(in: mailRoot),
                    sessionFor: AgentRegistry.sessionLookup(in: registryRoot))
                guard
                    let owner = book.owner(
                        foregroundPid: foreground, shellPid: shell,
                        // `AddressBook` defaults neither closure (#221): it lives in `HelmWire`,
                        // which depends on nothing in `Helm`, and `AgentLocator`/`AgentRegistry`
                        // are `Helm`-only. This is the call site that used to lean on a default.
                        ancestors: { AgentLocator.ancestors(of: $0) })
                else { return nil }
                return (foreground == shell ? nil : foreground, owner)
            })

        guard let resolved else {
            answer(
                request.id, .unclaimed, terminalId: TerminalID(terminal),
                pid: spawner.foregroundPid(of: terminal),
                reason:
                    "the terminal is alive but no mailbox appeared under \(mailRoot.path) within "
                    + "\(claimDeadline), so this agent cannot be addressed. Either it is not "
                    + "running the helm-mail hook/extension, or the command never started — "
                    + "look at the pane.")
            return
        }
        answer(
            request.id, .ready, terminalId: TerminalID(terminal),
            pid: resolved.agent ?? resolved.owner.pid, sessionId: resolved.owner.sessionId,
            // The blessed path: a `Handle` read out of the owner record `MailboxDirectory`
            // just resolved, never built from `cwd`/session id by hand. See `Handle`.
            handle: Handle(readingFrom: resolved.owner), runtime: resolved.owner.runtime)
    }

    /// Every success path funnels here, and the id it takes is a `RequestID` — so all 21 call
    /// sites hand over the one their `Accepted*` request already carries, and none of them can
    /// produce one any other way (#260).
    private func answer(
        _ id: RequestID, _ status: SpoolResult.Status, terminalId: TerminalID? = nil,
        pid: pid_t? = nil, sessionId: String? = nil, handle: Handle? = nil,
        runtime: String? = nil, reason: String? = nil, capture: CaptureReport? = nil,
        command: CommandReport? = nil, select: SelectReport? = nil, name: NameReport? = nil
    ) {
        directory.write(
            SpoolResult(
                id: id, status: status, terminalId: terminalId, pid: pid,
                sessionId: sessionId, handle: handle, runtime: runtime, reason: reason,
                capture: capture, command: command, select: select, name: name))
        NSLog(
            "helm: spool request %@ is %@%@%@%@%@%@", id.value, status.rawValue,
            handle.map { " — reachable at \($0.value)" } ?? "",
            capture.map { " — \($0.path), terminal content \($0.terminalContent.rawValue)" } ?? "",
            command.map { " — \($0.command.rawValue), \($0.panes) panes in \($0.columns) columns" }
                ?? "",
            select.map { " — pane \($0.pane.uuidString), visible \($0.isVisible)" } ?? "",
            name.map { " — pane \($0.pane.uuidString) is now \"\($0.name)\"" } ?? "")
    }

    /// Re-ask `probe` until it answers or the deadline passes.
    ///
    /// Bounded by a **budget** rather than an attempt count, so a slow machine buys more
    /// attempts instead of failing earlier — which is what both flaky process-spawning tests
    /// in this repo actually got wrong.
    private func poll<Value>(
        until deadline: Duration, for probe: @MainActor () -> Value?
    ) async -> Value? {
        let expiry = ContinuousClock.now.advanced(by: deadline)
        while ContinuousClock.now < expiry {
            if let value = probe() { return value }
            try? await Task.sleep(for: Self.pollInterval)
            if Task.isCancelled { return nil }
        }
        return probe()
    }
}
