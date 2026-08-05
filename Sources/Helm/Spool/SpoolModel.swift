import Foundation

/// What helm does with an accepted request, as a seam.
///
/// **The whole point of the seam is that the watcher half is reachable from `swift test`.**
/// #54 asks for it in as many words, and three defects in two days came from logic trapped in
/// a `View`. Everything on the other side of this protocol needs a window, a ghostty surface
/// and a real pty; everything on this side — claiming, refusing, timing out, resolving a
/// handle, writing a result — does not, and is tested without any of them.
@MainActor
protocol SpoolSpawning: AnyObject {
    /// Open a terminal running a login shell in `cwd`, and return the pane's id. Synchronous:
    /// the session exists the moment it is made, long before its surface attaches.
    func openTerminal(cwd: String) -> Result<UUID, SpoolRefusal>
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
    private var watcher: SpoolWatcher?

    /// Requests acted on in this process, by result id — so a second window's `drain` and this
    /// one's backstop cannot both answer the same request. Between *processes* the rename is
    /// what decides; this is the cheaper in-process half of the same rule.
    private var handled: Set<String> = []

    init(
        directory: SpoolDirectory = .resolve(),
        mailRoot: URL = MailboxDirectory.resolve(),
        isOff: Bool = SpoolDirectory.isOff(),
        shellDeadline: Duration = .seconds(20),
        claimDeadline: Duration = .seconds(90)
    ) {
        self.directory = directory
        self.mailRoot = mailRoot
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
        for id in directory.abandoned() where !handled.contains(id) {
            handled.insert(id)
            directory.write(
                SpoolResult(
                    id: id, status: .abandoned,
                    reason:
                        "helm stopped while this request was in flight. It was NOT re-run: a "
                        + "request is acted on at most once, so a restart must not double-open. "
                        + "Send it again if you still want it."))
            NSLog("helm: spool request %@ was abandoned by a restart", id)
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
                refuse(
                    id: fallbackID,
                    reason: "the request file is not readable JSON of the form "
                        + "{\"id\",\"kind\",…} — a spawn is "
                        + "{\"id\",\"cwd\",\"command\",\"args\",\"prompt\"}, a capture is "
                        + "{\"id\",\"kind\":\"capture\",\"path\",\"window\"}, a close is "
                        + "{\"id\",\"kind\":\"close\",\"terminal\",\"force\"}")
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
            }
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        return exists && directory.boolValue
    }

    private func refuse(id: String, reason: String) {
        // An id that is not a filename cannot name a result file, so there is nowhere to put
        // the answer. The log is all that is left, and it says so rather than pretending.
        guard id.range(of: SpoolPolicy.idPattern, options: .regularExpression) != nil else {
            NSLog(
                "helm: spool request refused and UNANSWERABLE (id %@ is not a filename): %@",
                id, reason)
            return
        }
        directory.write(SpoolResult(id: id, status: .refused, reason: reason))
        NSLog("helm: spool request %@ refused — %@", id, reason)
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
        let pane = closer.pane(request.terminal)
        if let refusal = SpoolClosePolicy.refusal(for: request, pane: pane) {
            refuse(id: request.id, reason: refusal.reason)
            return
        }
        guard closer.close(request.terminal) else {
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
        switch spawner.openTerminal(cwd: request.cwd) {
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
                request.id, .failed, terminalId: terminal,
                reason:
                    "a terminal was opened in helm but its shell never started within "
                    + "\(shellDeadline). Nothing was sent to it; it is sitting at an empty prompt.")
            return
        }

        // The line, not the line plus a Return: how a line is *submitted* is the adapter's
        // business, and it is not one write (see `WorkbenchSpoolSpawner.send`).
        spawner.send(SpoolLaunchLine.compose(request, promptPath: promptPath), to: terminal)
        answer(request.id, .started, terminalId: terminal)

        // **One wait with one budget, for two observables.** The pty's foreground pid moving
        // off the login shell is the pty saying the line actually ran; the mailbox appearing
        // is the agent saying it can be addressed. Waiting for them in sequence would spend
        // the deadline twice and make the worst case a caller sees twice as long as the number
        // this file names.
        let resolved = await poll(
            until: claimDeadline,
            for: { [mailRoot] () -> (agent: pid_t?, owner: MailboxOwner)? in
                let foreground = spawner.foregroundPid(of: terminal)
                guard
                    let owner = MailboxDirectory.owner(
                        in: MailboxDirectory.owners(in: mailRoot),
                        foregroundPid: foreground, shellPid: shell)
                else { return nil }
                return (foreground == shell ? nil : foreground, owner)
            })

        guard let resolved else {
            answer(
                request.id, .unclaimed, terminalId: terminal,
                pid: spawner.foregroundPid(of: terminal),
                reason:
                    "the terminal is alive but no mailbox appeared under \(mailRoot.path) within "
                    + "\(claimDeadline), so this agent cannot be addressed. Either it is not "
                    + "running the helm-mail hook/extension, or the command never started — "
                    + "look at the pane.")
            return
        }
        answer(
            request.id, .ready, terminalId: terminal, pid: resolved.agent ?? resolved.owner.pid,
            sessionId: resolved.owner.sessionId, handle: resolved.owner.handle,
            runtime: resolved.owner.runtime)
    }

    private func answer(
        _ id: String, _ status: SpoolResult.Status, terminalId: UUID? = nil, pid: pid_t? = nil,
        sessionId: String? = nil, handle: String? = nil, runtime: String? = nil,
        reason: String? = nil, capture: CaptureReport? = nil
    ) {
        directory.write(
            SpoolResult(
                id: id, status: status, terminalId: terminalId?.uuidString, pid: pid,
                sessionId: sessionId, handle: handle, runtime: runtime, reason: reason,
                capture: capture))
        NSLog(
            "helm: spool request %@ is %@%@%@", id, status.rawValue,
            handle.map { " — reachable at \($0)" } ?? "",
            capture.map { " — \($0.path), terminal content \($0.terminalContent.rawValue)" } ?? "")
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
