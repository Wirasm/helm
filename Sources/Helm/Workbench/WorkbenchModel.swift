import AppKit
import Combine
import Foundation
import HelmWire
import SwiftUI
import os

/// helm's side of the bench: the ACTIVE workspace's bench as benchd last sent it, the door every
/// change goes out through, and the resolver from the bench's values to the objects they name.
///
/// **benchd owns the bench (#354); this draws it.** Every change — a key, a click, a drag, a
/// `push.sh`, the spool — is a `BenchVerb` sent through `send`, which says who asked; benchd
/// applies its rules, and the document it made comes back on the follower and is drawn by
/// `apply`. Nothing here changes a bench itself, and `Workbench` has no method that could. With
/// benchd unreachable the last document stays on screen and a verb fails visibly
/// (`verbFailure`, and the status bar's capsule).
///
/// `TerminalManager` still owns every session, flat and app-wide, because a background
/// workspace's terminals must stay alive (`BoardModel.hostedPids` reads exactly that).
///
/// **Every command a vertical owns lives here, for the reason `TerminalWorkspace`'s header
/// gave and this makes truer.** That file kept the terminal commands inside the terminal
/// vertical so two features could be built without meeting in the same file. The
/// subscriptions did not stop being right — they moved up a level, because all of them are
/// *"act on the focused pane"* and focus is the bench's now. `AGENTS.md`'s rule is exact: a
/// subscription that has to work while its view is closed belongs on the model.
@MainActor
final class WorkbenchModel: ObservableObject {
    /// Nothing open, a question waiting on the operator, or a bench — as one value, so no
    /// combination of the two can be constructed that `MountState` does not name. Its header
    /// has the argument for why this is a type and not two paired Optionals.
    @Published private(set) var mount: MountState = .empty

    /// nil when no workspace is open — **or when a mount is waiting on an answer** (#85). Not
    /// an "empty bench": `Workbench`'s first invariant is that a bench always holds at least
    /// one pane, so there is no such value to make.
    ///
    /// Computed rather than stored: every reader outside this file reads what it always read,
    /// and `mount` is the one thing a writer can set.
    var bench: Workbench? { mount.bench }

    /// The unanswered mount question, if there is one (#85). See `BenchMountPolicy` for when
    /// it is asked and which bench it is about.
    var restoreOffer: BenchRestoreOffer? { mount.restoreOffer }

    /// The active workspace's shelf: a bench a *fresh* declined, kept by benchd so that one
    /// wrong click cannot destroy a layout (#85). Offered again by `BenchMountPolicy` in the one
    /// case where it is still the operator's live question.
    @Published private(set) var shelvedBench: Workbench?

    /// One resume offer per restored terminal pane that had an agent (#63), keyed by pane.
    ///
    /// **Not persisted, and `ResumableAgent`'s header says why**: the record of what was
    /// running belongs on the bench, the question about it belongs to this launch. Entries go
    /// when the operator answers, and when a tick of `observeAgents` finds a live agent in the
    /// pane after all — which is what makes an accepted resume put its own offer away.
    @Published private(set) var resumeOffers: [Pane.ID: AgentResumeOffer] = [:]

    /// ⌘O's popover. App chrome rather than slot chrome — it appears once, on the focused
    /// slot's strip, because repeating it on every strip would multiply it by N. The
    /// *state* is here rather than in a view because the command that opens it is.
    @Published var isBrowserOpen = false

    /// Why ⌘⇧N did not produce a note (#289) — no workspace open, or a `~/.prp` helm could not
    /// write to.
    ///
    /// **Here rather than on a canvas, because the failure is that there is no canvas.** Every
    /// other thing helm says about a note is a strip inside its own pane; this one happens before
    /// a pane exists, so it has to be said on the bench. A keystroke that silently does nothing is
    /// the shape of failure `AGENTS.md` records paying for repeatedly, and it is what this exists
    /// to stop being.
    ///
    /// Cleared by the next attempt that works, and by a timer — it is a receipt about a moment,
    /// not something to dismiss.
    @Published private(set) var noteFailure: String?
    private var noteFailureTask: Task<Void, Never>?

    private(set) var workspacePath: WorkspacePath?

    private let terminals: TerminalManager

    /// Every live pane object — sessions, canvases, browser views — keyed by pane id, one
    /// registry for every kind (`SurfaceKind`, PR 3a of #354). It is the terminal manager's, so
    /// the bench and the manager can never disagree about what is alive.
    private var surfaces: SurfaceRegistry { terminals.surfaces }

    /// Which terminal put each canvas pane on the bench (#205) — the key is the **canvas** pane,
    /// the value names the **terminal** pane, which is what `CanvasOrigin` exists to keep straight.
    ///
    /// Kept beside the canvas's model rather than on `Pane.Content.canvas`, and that is load-bearing:
    /// `CanvasSource` is compared by value to answer "is this file already open?"
    /// (`Workbench.pane(showing:)`), so an origin inside it would make the same artifact pushed by
    /// two agents two different sources — a second pane for a file already on screen, which is the
    /// interruption `offer` exists to avoid. It also must not persist; `CanvasOrigin`'s header has
    /// the reason.
    ///
    /// A push can land on a background workspace's bench (#349); the entry goes when the pane
    /// leaves the document (`apply`).
    private var origins: [Pane.ID: CanvasOrigin] = [:]

    /// How a mark leaves helm: as mail through benchd. Injected so the routing is reachable from
    /// `swift test` with a benchd the test answers for, and nothing sent to the operator's own.
    private let notes: CanvasNoteCourier

    /// How helm learns which agent is in a pane, and whether its transcript is still there
    /// (#63). Injected for `notes`' reason exactly: every rule that depends on it is then
    /// reachable from `swift test` against a fixture directory, on a machine that has never
    /// run Claude Code and with nothing read out of the operator's own `~/.claude`.
    private let agents: AgentObserver

    /// How a resume line reaches the pty it is meant for. A seam rather than a direct
    /// `hostView` call so `resume(_:)` is testable — the same trade `SpoolSpawning` makes for
    /// the spool, and the default is the same paste-then-Return the spool sends.
    private let launcher: TerminalLaunching

    /// Where the project stores are — `~/.prp` in production (#289).
    ///
    /// **One reader now, and that is the widening.** It used to be handed to `CanvasModel` too,
    /// because editability was a question about where the stores were and a pane that disagreed
    /// with `newNote` would create a note it then refused to open. `EditableFile` judges the file
    /// in front of the canvas instead, so the only thing that still needs this is deciding where
    /// a *new* note lands — and there is no second answer left to disagree with.
    ///
    /// Injected for `notes`' and `agents`' reason exactly: every rule below is then reachable
    /// from `swift test` against a temporary directory, with nothing written near the operator's
    /// own `~/.prp`.
    private let artifactRoot: URL

    /// A workspace folder → the repository root its notes are keyed by. `WorkspaceStore`'s
    /// `git` run in production, which has a deadline; injected so a test can hold the answer
    /// back or make it time out without a real git that hangs.
    private let resolveRepository: @Sendable (String) async throws -> String

    /// Workspaces shown, or asked about, in this process. #85's question is asked once per
    /// workspace per launch: re-asking on every switch back would make it chrome rather than a
    /// decision (`BenchDrawing`).
    private var answered: Set<WorkspacePath> = []

    /// Workspaces whose resume offers (#63) have been made in this process: at the first drawing
    /// of their bench, which after #85's question is the drawing that follows the answer. Its
    /// own set rather than `answered`, which the question marks before that drawing happens —
    /// sharing it made a restored bench's agents never offered at all.
    private var offered: Set<WorkspacePath> = []

    /// benchd, over its socket: a request per verb, and the follower that delivers documents.
    let client: BenchClient

    /// The document the bench was last drawn from. nil until benchd first answers.
    @Published private(set) var document: BenchDocument?

    /// Why the last verb did not happen — a refusal, or benchd unreachable. Said for a while and
    /// then taken away, like a note's failure: it is about a moment.
    @Published private(set) var verbFailure: String?
    private var verbFailureTask: Task<Void, Never>?

    /// Handed each document once the bench is drawn from it, so whoever holds the workspace list
    /// (`RootView`) can follow the document's workspaces too. Set through `followDocuments`.
    private var documentFollower: ((BenchDocument) -> Void)?

    /// Follow every document from now on — starting with the one already drawn, if benchd
    /// answered before the caller was ready. The first document usually wins that race: the
    /// client connects when this model is made, and `RootView` wires its follower in `.task`.
    func followDocuments(_ follower: @escaping (BenchDocument) -> Void) {
        documentFollower = follower
        if let document { follower(document) }
    }

    /// The document last drawn, kept so an answer to the mount question can draw it again.
    private var lastApplied: DocumentAt?

    /// `AnyCancellable`s rather than NotificationCenter tokens: they unsubscribe in their
    /// own deinit, and Swift 6 forbids a nonisolated deinit from touching the non-Sendable
    /// token the observer API hands back.
    private var commands: Set<AnyCancellable> = []

    /// Internal, not a `.shared`. `TerminalManager.shared` and `BoardModel.shared` are
    /// singletons because other slices reach them; nothing outside the workbench needs
    /// this one, and an injectable initialiser is what lets tests build isolated models.
    init(
        terminals: TerminalManager,
        notes: CanvasNoteCourier = CanvasNoteCourier(),
        agents: AgentObserver = .live(),
        launcher: TerminalLaunching? = nil,
        artifactRoot: URL = ArtifactStoreDiscovery.defaultRoot,
        resolveRepository: @escaping @Sendable (String) async throws -> String = {
            try await WorkspaceStore.repositoryRoot(for: $0)
        },
        makeBrowser: @escaping @MainActor () -> BrowserPaneModel = { BrowserPaneModel() },
        client: BenchClient
    ) {
        self.client = client
        self.terminals = terminals
        self.notes = notes
        self.agents = agents
        self.launcher = launcher ?? TerminalLineLauncher(terminals: terminals)
        self.artifactRoot = artifactRoot
        self.resolveRepository = resolveRepository
        // Registered here rather than by the manager because both need the bench: the canvas
        // kind the mark route, the browser kind a factory the caller chose. Re-registering
        // replaces, so a second model on one manager rewires them to itself.
        terminals.surfaces.register(
            CanvasPaneKind { [weak self] model, pane in self?.wireMarks(model, in: pane) })
        terminals.surfaces.register(BrowserPaneKind(make: makeBrowser))
        terminals.surfaces.register(UnsupportedPaneKind())
        terminals.surfaces.register(SessionsPaneKind(workbench: self, terminals: terminals))
        // The same rewiring for the manager's sessions: a ⌘-clicked link and a `push.sh` are
        // verbs, and this is the bench they are sent to.
        terminals.bench = self
        subscribe()
        client.onDocument = { [weak self] at in self?.apply(at) }
        client.start()
    }

    // MARK: - #85's question

    /// The operator's answer to the mount question (#85). See `answerFromDaemon`.
    func answer(_ choice: BenchRestoreChoice) {
        guard let path = workspacePath, let offer = restoreOffer else { return }
        answerFromDaemon(choice, offer: offer, path: path)
    }

    /// A spool spawn's `cwd`, opened and put on screen (#54): an agent's `workspace/open` that
    /// says the operator asked.
    ///
    /// **The one exception to "an agent's verb leaves the view alone", until M5b** (plan of
    /// #354). A terminal gets its ghostty surface, and so its pty, only when it is drawn, and helm
    /// draws only the workspace on screen — so a spawn opened in the background would paste its
    /// launch line into a shell that never started, and fail after the spool's deadline.
    func openWorkspaceForSpawn(_ workspace: Workspace) {
        send(.workspaceOpen(path: workspace.path.value), by: .agent(), asked: true)
    }

    /// Resolve an open mount question by restoring, on a request from outside (#85 × #54).
    ///
    /// **This is the one place helm answers the operator's own question for them, and it is
    /// argued rather than incidental.** A spool spawn exists for the case where nobody is at the
    /// pane, and #179's trade is exact: *a question nobody will be there to answer must be
    /// answered in advance, and answered so the agent can work.* **Restore rather than fresh**
    /// is the half that keeps it from being destructive: it is one of the two answers the
    /// operator was going to give, and it loses nothing.
    func mountWithoutAsking() {
        guard let path = workspacePath, let offer = restoreOffer else { return }
        answerFromDaemon(.restore, offer: offer, path: path)
    }

    /// One offer per pane whose record names an agent that is **not already running there**.
    ///
    /// The liveness check is what stops a switch away and back from re-offering an agent the
    /// operator already resumed: the record stays on the pane while the agent runs — that is
    /// the point of it — so "has a record" alone would ask about a conversation that is on
    /// screen.
    private func offers(in bench: Workbench?) -> [Pane.ID: AgentResumeOffer] {
        // A bench with nothing recorded on it has nothing to ask about, and asking costs two
        // directory reads — the registry, and a transcript lookup per pane. Every mount before
        // an agent has ever run in a workspace takes this branch, which is most of them.
        guard let bench, !bench.resumableAgents.isEmpty else { return [:] }
        let live = liveAgents(in: bench)
        return Dictionary(
            bench.resumableAgents.compactMap { pane, agent in
                guard live[pane] == nil else { return nil }
                return (
                    pane,
                    AgentResumeOffer.offer(
                        agent, in: pane, transcriptExists: agents.transcriptExists)
                )
            },
            // **`uniquingKeysWith:`, and first-in-bench-order.** A bench is decoded from
            // `UserDefaults` and nothing on the way in dedupes pane ids — `normalize()` says so
            // in its own words: *"unreachable through any mutation — but a decoded bench is not
            // built by a mutation, so this is not an assertion."* `uniqueKeysWithValues:` traps
            // on a duplicate, which here is a crash **at mount**, on every relaunch, that the
            // operator can only escape by hand-editing defaults. `AgentRegistry.rows(in:)` makes
            // exactly this argument on this same branch and is the reason to make it here too.
            //
            // First rather than last, because `Workbench.address(of:)` is a `firstIndex(where:)`
            // — so the first is the pane `record`, `resume` and `dismissResume` will all act on,
            // and an offer about the other one would answer a question about a pane nothing
            // touches.
            uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Which agent is in which pane (#63)

    /// Watch the panes for agents until cancelled — driven from `WorkbenchView`'s `.task`, so
    /// its lifetime is the window's and SwiftUI cancels it on teardown. The same shape, and
    /// the same two-second cadence, `BoardModel.poll` already runs against the same registry.
    ///
    /// **Polling, not watching**, for `BoardModel`'s reason: a session's row is rewritten in
    /// place, which a directory-level `DispatchSource` does not reliably see.
    func watchAgents(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            observeAgents()
            try? await Task.sleep(for: interval)
        }
    }

    /// One tick: write down who is in each pane, and put away any offer that has been answered
    /// by the agent turning up.
    ///
    /// **The record is sticky — set when an agent is seen, never cleared when it stops being
    /// seen.** That is deliberate and it is the whole point of the field. A `claude` running a
    /// bash command hands the pty's foreground to a child for as long as that command takes,
    /// so a record cleared on absence would be erased and rewritten several times a minute —
    /// a `pane/record` event each time, and, far worse, nothing at all if helm died inside one
    /// of those windows. A crash is exactly the case
    /// #63 exists for. The cost, recorded: an agent the operator exited on purpose is still
    /// offered on the next launch. That offer names its session and is one click to decline,
    /// which is the cheap side of the trade.
    ///
    /// **The active workspace only.** A background workspace's record is whatever was written
    /// while it was on screen, which is the last moment helm looked.
    func observeAgents() {
        guard let bench else { return }
        let live = liveAgents(in: bench)
        // Only a real change is sent: an identical record every two seconds would be an event
        // per tick in benchd's log for the life of the process.
        // Sent as `pane/record` by helm itself: an observation, never anyone's gesture. Not
        // while benchd is unreachable: each would wait out the request timeout on the main
        // thread, and a record not sent now is sent on the next tick.
        let reachable = if case .disconnected = client.state { false } else { true }
        for (pane, agent) in live where reachable {
            guard case let .terminal(recorded) = bench.pane(pane)?.content,
                recorded != agent
            else { continue }
            send(.paneRecord(pane, agent: BenchDocument.Agent(agent)), by: .helm)
        }
        // An offer whose pane now holds a live agent has been answered by events: the operator
        // accepted it, or started one by hand. Either way there is nothing left to ask.
        let stale = resumeOffers.keys.filter { live[$0] != nil }
        if !stale.isEmpty { for pane in stale { resumeOffers[pane] = nil } }
    }

    /// Which agent is running in each terminal pane **right now**, per Claude Code's own
    /// registry. Absent from the dictionary means the registry says nothing about that pane —
    /// never "there is no agent".
    private func liveAgents(in bench: Workbench) -> [Pane.ID: ResumableAgent] {
        // Re-read per call rather than captured: the row helm is waiting for is written by an
        // agent that has not started yet, so a lookup taken earlier could never see it.
        let rows = agents.sessionsNow()
        var found: [Pane.ID: ResumableAgent] = [:]
        for id in bench.terminalPaneIDs {
            guard let session = terminals.sessions.first(where: { $0.id == id }),
                let pid = agents.foregroundPid(session), let row = rows[pid],
                let sessionId = row.sessionId, !sessionId.isEmpty
            else { continue }
            found[id] = ResumableAgent(
                command: AgentResume.claude, session: sessionId,
                // The registry's own `cwd` when it has one — an agent started in a
                // subdirectory is not working in the workspace root, and it is the `cwd` that
                // finds the transcript.
                cwd: row.cwd ?? session.workspacePath.value)
        }
        return found
    }

    /// The operator accepted a pane's resume offer (#63).
    ///
    /// helm composes the agent's own `--resume` and puts it in that pane's pty. It does not
    /// reimplement resume, and it does not touch focus: the line goes to the surface helm
    /// created for that pane, so it cannot land in whatever pane holds the keyboard (#96).
    ///
    /// The offer is retired here rather than left for `observeAgents` to notice: the operator
    /// clicked, so the question is answered whether or not the agent turns up. The **record**
    /// stays on the pane, because it is still true — that agent is what is running there — and
    /// the next tick confirms it without writing anything.
    func resume(_ pane: Pane.ID) {
        guard let offer = resumeOffers[pane], offer.canResume,
            let line = AgentResume.line(resuming: offer.agent)
        else { return }
        resumeOffers[pane] = nil
        launcher.run(line, in: pane)
    }

    /// The operator declined a pane's resume offer, or acknowledged one helm cannot make good
    /// on. **The record goes with it** — a declined agent left on the pane is one that is
    /// offered again on every launch until the pane is closed.
    func dismissResume(_ pane: Pane.ID) {
        guard resumeOffers[pane] != nil else { return }
        resumeOffers[pane] = nil
        send(.paneRecord(pane, agent: nil), by: .operatorGesture)
    }

    // MARK: - Resolving panes to the objects they name

    /// A pane's body and its tab, from its kind — the one route every kind is drawn by, so
    /// nothing in the bench's views asks what kind a pane is.
    func surfaceView(of pane: Pane, in slot: SurfaceSlot) -> AnyView? {
        surfaces.view(of: pane, in: slot, workspace: home(of: pane.id))
    }

    func surfaceTab(of pane: Pane, in slot: SurfaceSlot) -> AnyView? {
        surfaces.tab(of: pane, in: slot, workspace: home(of: pane.id))
    }

    /// What a surface needs to know about where it is drawn, answered by the bench.
    func surfaceSlot(for pane: Pane, in slot: Slot) -> SurfaceSlot {
        SurfaceSlot(
            pane: pane,
            holdsKeyboard: openDrawer == nil && bench?.focusedPane?.id == pane.id,
            isSelected: pane.id == slot.selected,
            canClose: bench?.canClose(pane.id) ?? false,
            select: { [weak self] in self?.send(.paneShow(pane.id), by: .operatorGesture) },
            close: { [weak self] in self?.send(.paneClose(pane.id), by: .operatorGesture) })
    }

    func session(for pane: Pane) -> TerminalSession? {
        surfaces.existing(pane.id, as: TerminalSession.self)
    }

    /// Resolve-or-create, at the edge. The model is kept by pane id so a tab switch or a
    /// re-render gets the same webview back rather than reloading the page.
    func canvas(for pane: Pane) -> CanvasModel {
        guard let model = surfaces.resolve(pane, in: home(of: pane.id)) as? CanvasModel else {
            preconditionFailure("canvas(for:) asked about a pane that is not a canvas: \(pane)")
        }
        return model
    }

    /// The return path (#205), wired onto every canvas model the canvas kind makes. AFTER
    /// construction, so resolving a restored pane into its own canvas is not mistaken for a
    /// mark. The identity check keeps an ORPHAN quiet: a model that is no longer the registry's
    /// for its pane has no origin to route to any more. `model` is captured weakly because the
    /// closure is stored on it.
    private func wireMarks(_ model: CanvasModel, in pane: Pane.ID) {
        model.onAnnotation = { [weak self, weak model] annotation, canvas in
            guard let self, let model, surfaces.existing(pane, as: CanvasModel.self) === model
            else {
                return .notSent(.noOrigin)
            }
            return deliver(annotation, on: canvas, markedIn: pane)
        }
    }

    /// An operator's mark on a canvas pane, on its way to the agent that pushed that canvas
    /// (#205).
    ///
    /// **The bench is the only thing that can answer this**, which is why the decision is reached
    /// from here rather than from the canvas: it holds the origin recorded at push time *and* the
    /// sessions that origin names. What it does not do is *make* the decision —
    /// `CanvasNoteRoute.route` is pure and tested on its own, and this only supplies it with a
    /// live lookup.
    private func deliver(
        _ annotation: CanvasAnnotation, on canvas: URL, markedIn pane: Pane.ID
    ) -> CanvasNoteDelivery {
        let route = CanvasNoteRoute.route(origin: origins[pane]) { origin in
            // A closed pane resolves to no session, which is `.originGone` — the agent that
            // pushed this canvas is not there any more, and the operator is told so.
            terminals.sessions.contains { $0.id == origin.terminal }
                ? notes.handle(in: origin.terminal) : nil
        }
        return notes.send(annotation, on: canvas, along: route)
    }

    func browser(for pane: Pane) -> BrowserPaneModel {
        guard let model = surfaces.resolve(pane, in: home(of: pane.id)) as? BrowserPaneModel
        else {
            preconditionFailure("browser(for:) asked about a pane that is not a browser: \(pane)")
        }
        return model
    }

    /// What ⌘+/⌘0/⌘↑ act on.
    var focusedTerminal: TerminalSession? {
        bench?.focusedPane.flatMap(session(for:))
    }

    // MARK: - Commands

    /// ⌘⇧N — start a note and put the operator in it (#289).
    ///
    /// **`open` rather than `offer`, and the cursor placed rather than left where it was.** Every
    /// other route to a canvas pane weighs *appear, don't seize* (#125) because nobody asked for
    /// what is arriving. This one is the operator pressing a key and expecting to type, so seizing
    /// is the correct behaviour and the whole feature — which is also, exactly, why
    /// `SpoolCommandPolicy` refuses to let an agent send it.
    ///
    /// **Three decisions live elsewhere and are only called from here**, which is what keeps this
    /// method a wiring: where the note goes and what it is called are `OperatorNote.create`'s,
    /// where the pane lands is benchd's, and whether the file may be
    /// written into at all is `CanvasModel.write()`'s.
    ///
    /// - Parameter date: what day the filename says. Injected so the collision rule is testable
    ///   without waiting for midnight. *Where* the note goes is `artifactRoot`'s, which is one
    ///   value per model rather than a per-call argument — see its own note above.
    ///
    /// **Async because the store is keyed by a `git` answer** (#390). It used to run git on the
    /// main thread with no deadline, so a hung git froze the whole window. The wait is now
    /// `Subprocess`'s, holds no thread, and ends in a sentence after ten seconds. Everything
    /// after it is synchronous on the main actor, as before.
    @discardableResult
    func newNote(on date: Date = Date()) async -> Pane.ID? {
        // A bench is what a pane goes into, and a workspace is what names the store. Both are nil
        // together in practice; the message names the one the operator can act on.
        guard let path = workspacePath, bench != nil else {
            announceNoteFailure(OperatorNote.Failure.noWorkspace.sentence)
            return nil
        }
        let repository: String
        do {
            repository = try await resolveRepository(path.value)
        } catch {
            announceNoteFailure(OperatorNote.Failure.repositoryUnresolved(path.value).sentence)
            return nil
        }
        // The operator switched workspace while git ran. Nothing has been written yet, and a note
        // for the old project opened on the new one's bench would be in the wrong place.
        guard workspacePath == path, bench != nil else { return nil }
        do {
            let note = try OperatorNote.create(
                inRepository: repository, under: artifactRoot, on: date)
            guard
                let id = send(
                    .paneOpen(surface: .canvas(path: note.url.path)), by: .operatorGesture),
                let pane = bench?.pane(id)
            else { return nil }
            noteFailure = nil
            noteFailureTask?.cancel()
            // Straight into the writing face: the operator asked for somewhere to write, and a
            // rendered view of an empty file is a blank pane with a button on it.
            canvas(for: pane).write()
            return id
        } catch let failure as OperatorNote.Failure {
            announceNoteFailure(failure.sentence)
        } catch {
            announceNoteFailure(
                OperatorNote.Failure.couldNotWrite(
                    error.localizedDescription
                ).sentence)
        }
        return nil
    }

    /// Say why, and take it away again. The timer is `CanvasModel.announce`'s, for its reason:
    /// the message is a receipt about something that just happened, not a task.
    private func announceNoteFailure(_ sentence: String) {
        noteFailure = sentence
        noteFailureTask?.cancel()
        noteFailureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.noteFailure = nil
        }
    }

    /// Write every open draft now (#289).
    ///
    /// The app being quit, after which a debounced save can no longer happen. A canvas leaving
    /// the document is closed through its kind, and its `close()` saves too.
    func flushNotes() {
        for canvas in surfaces.models(CanvasModel.self) { canvas.saveDraft() }
    }

    // MARK: - Visibility

    /// Push what a session cannot know for itself onto every session in the app: `isVisible`,
    /// and — since #313 — the pane's name.
    ///
    /// On **every** document, not just on select: a close, a split or a focus move can all
    /// change which panes are on screen. Sessions in background workspaces are invisible by
    /// definition, which is why this walks every session rather than only this workspace's.
    ///
    /// **The name is pushed here rather than handed to the tab view, and that is what makes
    /// there be one answer to "what is this pane called" (#313).** `TerminalSession.displayTitle`
    /// is spent by three readers — the tab, `TerminalNotifier`, and `BenchSnapshot.TerminalRecord`
    /// — so a name the *view* knew about would have left `snapshot.json` reporting the OSC title
    /// while the tab beside it read something else. It is the same shape as `isVisible` for the
    /// same reason: a fact that belongs to the bench, about a session that has no way to ask.
    ///
    /// **A background workspace's sessions keep the name they were last pushed** until it is
    /// on screen again (`WorkbenchSpoolPanes.pane` reads the mounted bench and answers nil for
    /// everything else).
    ///
    /// It does nothing else. An earlier draft of this plan had it keep one `hostView`
    /// attached at 1×1pt in case zero attached ghostty surfaces stalled every pty — that
    /// was measured and it does not: a backgrounded pty ran a delayed command to completion
    /// with every surface unmounted. Do not reintroduce it from reading
    /// `TerminalSession`'s header, which predicts the opposite and is wrong about this.
    private func reconcileSessions() {
        let visible = bench?.visiblePaneIDs ?? []
        let names = Dictionary(
            (bench?.panes ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for session in terminals.sessions {
            let mine = session.workspacePath == workspacePath
            session.isVisible = mine && visible.contains(session.id)
            if let name = names[session.id] { session.name = name }
        }
    }

    // MARK: - Subscriptions

    private func subscribe() {
        // **⌘Q is the ordinary way to leave, and it reached no flush point at all** (#289).
        // Every other exit a note has — Read, closing the pane, pointing the canvas elsewhere,
        // closing the last workspace — is one of helm's own code paths. Quitting is not: the
        // process goes away with the debounce still pending, and a note typed in one burst with
        // no 600ms gap in it has never been written even once, so what is lost is the *whole
        // note* rather than a bounded tail. That is not a corner — "jot it down, ⌘Q" is the
        // shape of the feature.
        //
        // **Synchronous, with no `receive(on:)`**, and that is the point: the run loop is about
        // to stop, so a hop to the main queue is a save that never runs. AppKit posts this on
        // the main thread already.
        //
        // What it still does not cover is `kill -9`, and nothing can. That is the honest
        // remainder of `CanvasModel.saveDebounce`'s cost.
        NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.flushNotes() }
            }
            .store(in: &commands)
    }
}

// MARK: - The door

extension WorkbenchModel {
    /// How long a caller waits for the frame its verb made before reading the bench anyway.
    static let frameWait: TimeInterval = 1

    /// Every change to the bench, from anyone: `verb` is sent to benchd as `by`, and `asked` is
    /// the caller saying the operator asked for it, which lets an agent's verb take the keyboard
    /// the way the operator's own gesture does. benchd's focus rule reads both.
    ///
    /// Returns the pane the verb created or brought forward, when it did one of those; nil when
    /// it did neither, or did not happen — and then `verbFailure` says why.
    ///
    /// **Blocking, and that is the point.** A verb is one round trip on a local socket — spike
    /// S1 measured the whole path, send to `@Published`, at p99 under 6 ms. Blocking keeps verbs
    /// in the order they were made, and it lets a caller read what its verb did before it
    /// returns: benchd hands the frame to its followers before it answers, so
    /// `document(atLeast:)` has it.
    @discardableResult
    func send(_ verb: BenchVerb, by actor: BenchActor, asked: Bool = false) -> Pane.ID? {
        let request = BenchRequest(
            id: "helm-\(UUID().uuidString.lowercased())", verb: verb, by: actor, asked: asked)
        let started = DispatchTime.now()
        let answer: BenchResponse<LayoutReport>
        do {
            answer = try client.request(request, answering: LayoutReport.self)
        } catch {
            verbFailed("\(verb.name): \(error)")
            return nil
        }
        // An `error` can still carry a report: applied and logged, but bench.json not written.
        // The change is real, so it is drawn; the failure is said.
        if let report = answer.data, report.changed {
            let drawn = client.document(atLeast: report.seq, within: Self.frameWait) != nil
            // The round trip the operator feels: verb out, benchd's answer, the document it made
            // drawn. `log stream --predicate 'category == "bench"'` reads it.
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            Self.log.info(
                "\(verb.name, privacy: .public) by \(actor.kind, privacy: .public): \(ms, format: .fixed(precision: 2), privacy: .public) ms, drawn \(drawn, privacy: .public)"
            )
        }
        guard answer.status == .ok, let report = answer.data else {
            verbFailed(
                "benchd \(answer.status.rawValue) \(verb.name): \(answer.reason ?? "no reason given")"
            )
            return nil
        }
        return report.paneCreated ?? report.pane
    }

    private static let log = Logger(subsystem: "com.wirasm.helm", category: "bench")

    /// An agent's `push.sh` (#125): the canvas is offered as a `pane/open` from that agent, and
    /// the terminal it came from is remembered so a mark the operator later makes on the canvas
    /// can be mailed back to it (#205).
    ///
    /// **Recorded whether the pane is new or already open, and the second case is the common
    /// one** — an agent re-offering the file it just rewrote gets the pane that was there, and
    /// the newest pusher is the one who wants to hear about a mark on it. For a background
    /// workspace's bench too: `origins` is keyed by pane id and survives a switch, and `deliver`
    /// resolves the origin against every workspace's sessions.
    ///
    /// **A re-push re-reads the file (#261).** benchd answers the pane already showing it, and
    /// leaves it where it is; its render is helm's, and a canvas watches one file, so an agent
    /// that rewrote only a sibling (`app.js`) fired no watcher at all. A pane never resolved into
    /// a canvas has no render yet and reads the file when it first is.
    ///
    /// The origin is kept here rather than read back off the verb's actor: benchd records who
    /// asked and no rule reads it, and which agent a mark goes to is helm's concern.
    @discardableResult
    func push(_ artifact: URL, from origin: CanvasOrigin, in workspace: WorkspacePath) -> Pane.ID? {
        guard
            let pane = send(
                .paneOpen(workspace: workspace.value, surface: .canvas(path: artifact.path)),
                by: .agent(pane: origin.terminal.uuidString))
        else { return nil }
        origins[pane] = origin
        surfaces.existing(pane, as: CanvasModel.self)?.refresh()
        return pane
    }

    /// A ⌘-clicked http address (#376): the address becomes a new tab of the shared browser, in
    /// the background. helm opens the browser pane itself rather than as the operator's gesture,
    /// so it lands where the placement rules send it without taking the keyboard from the
    /// terminal clicked in: by default the browser drawer, which it badges (#356).
    func openLink(_ link: URL) {
        guard let id = send(.paneOpen(surface: .browser), by: .helm) else { return }
        browser(for: Pane(id: id, content: .browser)).open(link)
    }
}

// MARK: - Drawn from benchd (#354)

extension WorkbenchModel {

    /// Draw the bench from benchd's document. Every change reaches the screen
    /// this way — the operator's key and an agent's verb alike — and nothing else writes `mount`.
    ///
    /// **What helm keeps for itself is the live objects**, reconciled against the document:
    /// a pane in no workspace any more has its object closed through its kind, and the terminals
    /// of the workspace on screen get a session each. A background workspace's terminals get
    /// theirs when it is first shown: a terminal's pty starts only once it is drawn, so a session
    /// made earlier would hold nothing — and on the first document after the import it would
    /// start the shells #85's question is about to ask whether to restore.
    ///
    /// **#85's question stays helm's** (D4): a bench worth asking about is not drawn until the
    /// operator answers, and the answer goes back to benchd as a verb.
    ///
    /// **Re-entered, by design.** A verb sent from inside `documentFollower` (the import) waits
    /// for the document it made, and that calls this again before the outer call returns. Each
    /// call draws the document it was handed, and nothing after `documentFollower` reads local
    /// state, so the inner call's newer document is what stays drawn. Keep it that way.
    func apply(_ at: DocumentAt) {
        let document = at.document
        lastApplied = at
        self.document = document

        let alive = document.paneIDs
        for entry in surfaces.entries where !alive.contains(entry.id) {
            surfaces.close(entry.id)
        }
        origins = origins.filter { alive.contains($0.key) }
        resumeOffers = resumeOffers.filter { alive.contains($0.key) }

        let drawing = BenchDrawing.of(document, answered: answered)
        workspacePath = drawing.workspace
        shelvedBench = drawing.shelved
        mount = drawing.mount
        if let active = drawing.workspace, let bench = drawing.mount.bench {
            answered.insert(active)
            terminals.adopt(terminals: bench.terminalPaneIDs, in: active)
            if offered.insert(active).inserted { resumeOffers = offers(in: bench) }
        } else if drawing.workspace == nil {
            terminals.deactivate()
        }
        reconcileSessions()
        documentFollower?(document)
    }

    /// #85's answer. Restoring draws what benchd already holds, bringing the shelf
    /// back first when the offer was the shelf. Fresh asks benchd to shelve the bench and start
    /// one shell — unless the offer was the shelf, which fresh leaves where it is.
    ///
    /// **A verb that did not happen leaves the question open.** Marked answered before the verb,
    /// because the document it makes arrives inside the send and must not be asked about again;
    /// unmarked if no newer document came back, so the operator's choice is never silently
    /// replaced by the bench he declined.
    private func answerFromDaemon(
        _ choice: BenchRestoreChoice, offer: BenchRestoreOffer, path: WorkspacePath
    ) {
        answered.insert(path)
        let offeredTheShelf = shelvedBench == offer.bench
        let verb: BenchVerb? =
            switch choice {
            case .restore where offeredTheShelf: .workspaceUnshelve(path: path.value)
            case .fresh where !offeredTheShelf: .workspaceReset(path: path.value)
            case .restore, .fresh: nil
            }
        if let verb {
            let before = lastApplied?.seq
            send(verb, by: .operatorGesture)
            guard lastApplied?.seq != before else {
                answered.remove(path)
                return
            }
        }
        if let lastApplied { apply(lastApplied) }
    }

    /// Say why a verb did not happen. A refusal is benchd's own sentence.
    func verbFailed(_ why: String) {
        NSLog("helm: %@", why)
        verbFailure = why
        verbFailureTask?.cancel()
        verbFailureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.verbFailure = nil
        }
    }
}
