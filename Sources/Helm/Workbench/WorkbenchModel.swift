import AppKit
import Combine
import Foundation
import HelmWire
import SwiftUI

/// The live workbench for the ACTIVE workspace, and the resolver from the bench's values
/// to the objects they name.
///
/// `TerminalManager` still owns every session, flat and app-wide, because a parked
/// workspace's terminals must stay alive (`BoardModel.hostedPids` reads exactly that).
/// What moved here is SELECTION, which under a bench is per slot and cannot be a single
/// app-level id.
///
/// **Every command a vertical owns lives here, for the reason `TerminalWorkspace`'s header
/// gave and this makes truer.** That file kept the terminal commands inside the terminal
/// vertical so two features could be built without meeting in the same file. The
/// subscriptions did not stop being right — they moved up a level, because all of them are
/// *"act on the focused pane"* and focus is the bench's now. `AGENTS.md`'s rule is exact: a
/// subscription that has to work while its view is closed belongs on the model.
@MainActor
// swiftlint:disable:next type_body_length - legacy (#418): 450 lines, limit 350
final class WorkbenchModel: ObservableObject {
    /// Nothing open, a question waiting on the operator, or a bench — as one value, so no
    /// combination of the two can be constructed that `MountState` does not name. Its header
    /// has the argument for why this is a type and not two paired Optionals.
    @Published private(set) var mount: MountState = .empty

    /// nil when no workspace is open — **or when a mount is waiting on an answer** (#85). Not
    /// an "empty bench": `Workbench`'s first invariant is that a bench always holds at least
    /// one pane, so there is no such value to make. A nil bench is exactly what makes
    /// `WorkspaceModel.saveContext` return early, which is what keeps a saved bench intact
    /// while the question about it is open.
    ///
    /// Computed rather than stored: every reader outside this file reads what it always read,
    /// and `mount` is the one thing a writer can set.
    var bench: Workbench? { mount.bench }

    /// The unanswered mount question, if there is one (#85). See `BenchMountPolicy` for when
    /// it is asked and which bench it is about.
    var restoreOffer: BenchRestoreOffer? { mount.restoreOffer }

    /// A bench a *fresh* declined, kept so that one wrong click cannot destroy a layout (#85).
    /// Read back into `WorkspaceContext.shelvedBench` by `WorkspaceModel.saveContext`, and
    /// offered again by `BenchMountPolicy` in the one case where it is still the operator's
    /// live question.
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
    /// **Stamped with the workspace whose bench holds the pane**: a push can land on a parked
    /// bench (#349) and never be resolved into a canvas, so the registry cannot tell
    /// `closeWorkspace` it is there.
    private var origins: [Pane.ID: PushedBy] = [:]

    private struct PushedBy {
        let origin: CanvasOrigin
        let workspacePath: WorkspacePath
    }

    /// Where a push from a workspace that is not mounted goes (#349). A parked workspace's bench
    /// is a value in `WorkspaceModel.contexts`, which this model cannot reach, and without this a
    /// push from one was dropped while `push.sh` reported success.
    ///
    /// Weak because `WorkspaceModel.observe` already holds this model strongly; both are the
    /// root view's `@StateObject`s, so neither outlives the other. nil drops a parked push, which
    /// is what a test that never wires it gets.
    weak var parked: ParkedBenches?

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

    /// Workspaces whose mount question has already been answered in this process. A switch
    /// away and back re-mounts, and re-asking then would make the question chrome rather than
    /// a decision — `BenchMountPolicy.mount` takes this as `answered`.
    private var answered: Set<WorkspacePath> = []

    /// Where the bench comes from: helm's own state, or benchd's document (#354).
    let mode: BenchMode

    /// Where every verb goes (`VerbSink`): applied here, or sent to benchd.
    private lazy var sink: any VerbSink = {
        switch mode {
        case .local: LocalSink(workbench: self)
        case let .daemon(client): DaemonSink(workbench: self, client: client)
        }
    }()

    /// The document the bench was last drawn from, in daemon mode. nil in local mode, and in
    /// daemon mode until benchd first answers.
    @Published private(set) var document: BenchDocument?

    /// Why the last verb did not happen, in daemon mode — a refusal, or benchd unreachable. Said
    /// for a while and then taken away, like a note's failure: it is about a moment.
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

    /// Every pane id in the last document, so a terminal that appears in a later one can be
    /// started wherever it is. nil before the first.
    private var knownPanes: Set<Pane.ID>?

    /// The document last drawn, kept so an answer to the mount question can draw it again.
    private var lastApplied: DocumentAt?

    /// Opening, closing and switching workspaces, which `RootView` carries out because they span
    /// the workspace list and the bench together. nil in a test that has no workspace list.
    var workspaceVerbs: ((WorkspaceVerb) -> Void)?

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
        mode: BenchMode = .local
    ) {
        self.mode = mode
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
        if let client = mode.client {
            client.onDocument = { [weak self] at in self?.apply(at) }
            client.start()
        }
    }

    // MARK: - Lifecycle

    /// Makes a workspace's bench the live one. Lazy on first visit, exactly like
    /// `TerminalManager.activate`, and for the same reason: nothing spawns a pty until the
    /// workspace is actually visited.
    ///
    /// `restoring` is the persisted bench — or the one `migrating(from:)` built out of a
    /// pre-bench context. Its terminal pane ids ARE session ids, so they go straight to
    /// `TerminalManager.activate(restoring:)` and the row comes back under them.
    ///
    /// **This form mounts, and asks nobody** — the behaviour helm has always had, and still
    /// the right one everywhere there is no operator at the pane: a spool spawn's `cwd`
    /// becoming a workspace (#54), and a test that wants a bench to exist. See
    /// `activate(workspacePath:offering:shelved:)` for the operator's own mount, which may
    /// stop and ask (#85).
    func activate(
        workspacePath path: WorkspacePath, restoring restorable: Workbench? = nil,
        shelved: Workbench? = nil
    ) {
        workspacePath = path
        shelvedBench = shelved
        build(path, restoring: restorable)
    }

    /// The operator's own mount: the same activation, except that a bench worth asking about
    /// **stops and asks first** (#85).
    ///
    /// Paired with `activate(workspacePath:restoring:)` exactly as
    /// `Workbench.splitRight(offering:)` is paired with `splitRight(with:)`, and for a stronger
    /// reason than symmetry — see `BenchMountPolicy`'s header for the spawn that would
    /// otherwise have hung against a question nobody was there to answer.
    ///
    /// While the question is open *nothing happens*: no pty is spawned, no bench is built, and
    /// nothing is written over what is saved. Reopening 17 panes silently and offering to
    /// reopen 17 panes are the difference between a hazard and an annoyance, and only one of
    /// them can be declined.
    func activate(
        workspacePath path: WorkspacePath, offering restorable: Workbench?,
        shelved: Workbench? = nil
    ) {
        workspacePath = path
        shelvedBench = shelved
        switch BenchMountPolicy.mount(
            saved: restorable, shelved: shelved, answered: answered.contains(path))
        {
        case let .ask(offer):
            // Deliberately *before* `TerminalManager.activate`: that call spawns a shell for a
            // workspace with nothing to restore, and a question that has already spawned the
            // thing it is asking about is not a question.
            mount = .awaitingRestore(offer)
            resumeOffers = [:]
            reconcileSessions()
        case let .restore(saved):
            build(path, restoring: saved)
        case .fresh:
            build(path, restoring: nil)
        }
    }

    /// The operator's answer to the mount question (#85).
    ///
    /// **Fresh shelves rather than discards.** *"One wrong click should not destroy a layout.
    /// Fresh means do not open it now, never forget it."* The declined bench goes to
    /// `shelvedBench`, which `WorkspaceModel.saveContext` writes beside the live one — so the
    /// bench that is about to be persisted over it is not the only copy.
    func answer(_ choice: BenchRestoreChoice) {
        guard let path = workspacePath, let offer = restoreOffer else { return }
        if mode.client != nil { return answerFromDaemon(choice, offer: offer, path: path) }
        answered.insert(path)
        switch choice {
        case .restore:
            // **Only the bench that was just opened stops being shelved.** `BenchMountPolicy`
            // asks about the *saved* bench unless that is a bare shell, so a shelf can still be
            // sitting there while the operator restores something else entirely — and clearing
            // it then would be the destruction the shelf exists to prevent, reached through the
            // other button.
            if shelvedBench == offer.bench { shelvedBench = nil }
            build(path, restoring: offer.bench)
        case .fresh:
            shelvedBench = offer.bench
            build(path, restoring: nil)
        }
    }

    /// Resolve an open mount question by restoring, on a request from outside (#85 × #54).
    ///
    /// **This is the one place helm answers the operator's own question for them, and it is
    /// argued rather than incidental.** It used to happen as a side effect: a spawn re-activated
    /// whenever `bench == nil`, and #85 gave that condition a second meaning. So the operator
    /// could be looking at *"Restore 5 panes?"* and have it answered from a file on disk, with
    /// no named code path saying so and no test measuring it.
    ///
    /// It still resolves rather than refusing, and that is the trade #179 already ruled on:
    /// *a question nobody will be there to answer must be answered in advance, and answered so
    /// the agent can work.* A spawn that blocked until a human clicked would be dead exactly
    /// when the spool is worth having — screen locked, headless, over ssh. **Restore rather
    /// than fresh** is the half that keeps it from being destructive: it is one of the two
    /// answers the operator was going to give, it loses nothing, and #54 already accepts that
    /// a spawn switches their view.
    ///
    /// What it does not do is go back through `WorkspaceModel.open`/`select` — the workspace is
    /// already the mounted one, and re-selecting it would be a second, wider seizure for no gain.
    func mountWithoutAsking() {
        guard let path = workspacePath, let offer = restoreOffer else { return }
        if mode.client != nil { return answerFromDaemon(.restore, offer: offer, path: path) }
        // **The same line `answer(.restore)` runs, because this *is* that answer reached
        // another way.** Leaving it out was a real gap and it had a shape worth naming: the two
        // paths agreed about everything the header argues — restore, never fresh, exactly what
        // was offered — and disagreed about one piece of bookkeeping neither sentence mentions.
        // The offer can come from the shelf rather than from the saved bench
        // (`BenchMountPolicy.candidate`), and a shelf left naming a bench that is now live is
        // persisted by the next save; the operator closing back down to one empty shell would
        // then be offered a frozen snapshot they never declined.
        if shelvedBench == offer.bench { shelvedBench = nil }
        build(path, restoring: offer.bench)
    }

    /// Build the bench and everything that follows from it. The body `activate` used to be,
    /// plus the resume offers a restored bench brings with it.
    private func build(_ path: WorkspacePath, restoring restorable: Workbench?) {
        answered.insert(path)
        terminals.activate(workspacePath: path, restoring: restorable?.terminalPaneIDs ?? [])
        // The manager is the authority on which terminals exist — it may have just made a
        // fresh shell for a workspace with nothing persisted, and that shell's id is not
        // in any restored bench.
        let live = terminals.sessions(for: path).map(\.id)
        // `defaultBench` is nil only when the manager opened nothing, which it does not do for
        // a real workspace — so this is `.empty` rather than a bench with no panes, which
        // `Workbench`'s first invariant forbids anyone to construct.
        let built = restorable ?? Self.defaultBench(for: live)
        mount = built.map(MountState.mounted) ?? .empty
        resumeOffers = offers(in: built)
        reconcileSessions()
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

    func deactivate() {
        workspacePath = nil
        mount = .empty
        shelvedBench = nil
        resumeOffers = [:]
        // What does not outlive an unmount — canvases and browser views — is let go through
        // its kind, and a canvas's `close()` saves a draft being typed (#289): the last moment a
        // save can happen. **A save is not guaranteed here**: `saveDraft` refuses while a `CanvasConflict` is up — somebody else wrote the
        // file and helm will not overwrite bytes the operator has not been shown. Deliberate,
        // argued at `CanvasModel.saveDraft`, the same position `close()` and ⌘Q take, and pinned
        // per exit by `CanvasEditorTests` and `WorkbenchNoteTests`.
        //
        // This used to drop the canvas models **without** closing them, after a separate flush,
        // which left each one's `FileWatcher` open with nothing showing it. Closing is now one
        // path for every kind (`SurfaceRegistry.unmount`).
        surfaces.unmount()
        // Keyed by canvas pane id, so it goes exactly when the canvases do — a leftover entry
        // would name a pane nothing resolves any more.
        origins.removeAll()
        reconcileSessions()
    }

    /// Closing a workspace is an explicit teardown, unlike switching: every pane object it
    /// owned goes through its kind — a canvas's `FileWatcher` and its descriptor, a browser
    /// view's connection, a session's pty. Called the same way as
    /// `TerminalManager.closeWorkspace`, which reaches the same registry: unconditionally,
    /// naming the workspace, whether or not it is the active one.
    ///
    /// **Deliberately not done on a workspace SWITCH.** The cache surviving a switch is
    /// what gets the same webview back instead of a reload, and pane ids are persisted, so
    /// switching back finds its canvases still there. `activate` is right to leave it
    /// alone; only closing is a teardown.
    func closeWorkspace(_ path: WorkspacePath) {
        surfaces.closeWorkspace(path)
        origins = origins.filter { $0.value.workspacePath != path }
    }

    /// Today's frame, built out of whatever sessions the manager has: one column, one
    /// slot, the terminals as tabs. nil only when there are none, which
    /// `TerminalManager.activate` does not leave behind.
    private static func defaultBench(for sessions: [Pane.ID]) -> Workbench? {
        guard !sessions.isEmpty else { return nil }
        return Workbench(panes: sessions.map { Pane(id: $0, content: .terminal()) })
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
    /// churning `UserDefaults` through `WorkspaceModel.observe`, and, far worse, leaving
    /// nothing at all if helm died inside one of those windows. A crash is exactly the case
    /// #63 exists for. The cost, recorded: an agent the operator exited on purpose is still
    /// offered on the next launch. That offer names its session and is one click to decline,
    /// which is the cheap side of the trade.
    ///
    /// **The active workspace only.** A parked workspace's arrangement is a value in
    /// `WorkspaceModel.contexts` and nothing can mutate it until it is mounted again — the
    /// same rule `canvas(_:didPointAt:)` states one method over. Its record is whatever was
    /// written before it was parked, which is the last moment helm could see it.
    func observeAgents() {
        guard let bench else { return }
        let live = liveAgents(in: bench)
        // Only a real change is committed. Every commit reaches `UserDefaults`, and an
        // identical record written every two seconds is a write per tick for the life of the
        // process — the same reasoning `canvas(_:didPointAt:)` gives for asking whether the
        // source actually moved.
        // Sent as `pane/record` by helm itself: an observation, never anyone's gesture. Not
        // while benchd is unreachable: each would wait out the request timeout on the main
        // thread, and a record not sent now is sent on the next tick.
        let reachable = if case .disconnected = mode.client?.state { false } else { true }
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
        guard var bench, resumeOffers[pane] != nil else { return }
        resumeOffers[pane] = nil
        bench.record(nil, in: pane)
        commit(bench)
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
        let route = CanvasNoteRoute.route(origin: origins[pane]?.origin) { origin in
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

    /// Show the shared browser (#350) — **offered, never seizing**, from the operator's key as
    /// much as from an agent's command: the pane appears (or, if one is open, its slot shows it)
    /// and the keyboard stays where it was. The browser is something to glance at while work
    /// goes on, and an agent opening it must not pull the operator out of the pane he is typing
    /// in. He clicks it when he wants to use it.
    ///
    /// Returns the pane showing the browser.
    @discardableResult
    func offerBrowser(_: LocalBenchKey) -> Pane.ID? {
        guard var bench else { return nil }
        let placement = bench.placementForBrowser()
        let shown: Pane
        if case let .existing(open) = placement, let existing = bench.pane(open) {
            // Bring it forward only in a slot the operator is not in. In his own slot, showing
            // a background tab *is* moving his keyboard — the focused slot's selection is the
            // focused pane (`SpoolSelectPolicy`'s rule) — so the pane stays where it is.
            if bench.slot(for: open)?.id != bench.focusedSlot {
                bench.select(offering: open)
                commit(bench)
            }
            shown = existing
        } else {
            shown = Pane(content: .browser)
            bench.offer(shown, at: placement)
            commit(bench)
        }
        return shown.id
    }

    /// What ⌘+/⌘0/⌘↑ act on.
    var focusedTerminal: TerminalSession? {
        bench?.focusedPane.flatMap(session(for:))
    }

    // MARK: - Commands

    /// Returns the session it made, because a caller that did not press ⌘N needs the id: the
    /// spool has to write it into `results/<id>.json` and then send a launch line to that
    /// exact pane. nil is the honest answer when there is no workspace to open one in.
    @discardableResult
    func newTerminal(_: LocalBenchKey) -> TerminalSession? {
        guard let path = workspacePath, var bench else { return nil }
        let session = terminals.newTerminal(in: path)
        bench.insert(
            Pane(id: session.id, content: .terminal()),
            at: bench.placementForNewTerminal())
        commit(bench)
        return session
    }

    /// A terminal helm was asked to open **from outside** — the spool's spawn (#54), which is
    /// the same tenant `newTerminal` makes and two different decisions about it.
    ///
    /// Where it lands is `Workbench.placementForSpawnedTerminal()`'s — a new column of its
    /// own at the right end, decided by the bench rather than by whatever the operator last
    /// clicked. That it *appears* rather than seizing is `Workbench.offer(_:at:)`'s (#125):
    /// `selected` and `focusedSlot` are both left exactly as they were, so the keyboard stays
    /// in the pane the operator is typing in. A spawn nobody asked for that takes the
    /// keyboard is worse than one in an odd slot.
    ///
    /// Returns the session for the same reason `newTerminal` does: the spool has to write
    /// its id into `results/<id>.json` and then send the launch line to that exact pane.
    @discardableResult
    func spawnTerminal(_: LocalBenchKey) -> TerminalSession? {
        guard let path = workspacePath, var bench else { return nil }
        let session = terminals.newTerminal(in: path)
        bench.offer(
            Pane(id: session.id, content: .terminal()),
            at: bench.placementForSpawnedTerminal())
        commit(bench)
        return session
    }

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
    /// where the pane lands is `Workbench.placement(forOpening:)`'s, and whether the file may be
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

    /// Where an offered canvas lands is `Workbench.placement(forOpening:)`'s decision, not
    /// this method's. Returns the pane actually showing the source — which for an
    /// already-open one is the pane that was there, not a second copy.
    @discardableResult
    func open(_: LocalBenchKey, _ source: CanvasSource) -> Pane.ID? {
        guard var bench else { return nil }
        let placement = bench.placement(forOpening: source)
        let pane = Pane(content: .canvas(source))
        bench.insert(pane, at: placement)
        commit(bench)
        if case let .existing(open) = placement { return open }
        return pane.id
    }

    /// An agent putting an artifact on the bench. Same placement rules as `open`, but it
    /// **appears** rather than seizing — see `Workbench.offer(_:at:)` (#125).
    ///
    /// An artifact already on the bench keeps its pane, its slot and its tab — nothing is
    /// pulled forward, nothing is selected, focus does not move. What it does **not** keep is
    /// its render: a re-push is a request to show that file again, and the pane re-reads it
    /// where it already is (#261).
    ///
    /// **This used to return without refreshing anything**, on the stated reasoning that
    /// *"`FileWatcher` has already re-rendered that pane"*. That is true of the artifact and
    /// false of everything beside it. `CanvasModel.open` watches exactly one url, so an agent
    /// that rewrote only `app.js` fired no event at all — and this, the one path left that
    /// could still refresh the pane, declined on the strength of a refresh that never
    /// happened. The failure was silent and pointed the wrong way: the page kept rendering the
    /// old bytes, so the natural reading was "my change did not work" and the next move was to
    /// edit code that was not being re-read. It is also what #228 really was — `./app.js?v=2`
    /// worked because rewriting the import URL edits the **`.html`**, which is the file the
    /// watcher was on all along, and never because it busted a cache.
    ///
    /// **A refresh is not a seizure, and that distinction is the whole design.** What "appear,
    /// don't seize" protects is `selected` and `focusedSlot` (`Workbench.offer(_:at:)`), and
    /// neither is touched here — the pane redraws exactly where it was, still behind whatever
    /// tab it was behind. What it costs is **scroll position**, on a push that may have
    /// changed nothing. That is the trade, and it is not close: a push is an explicit act by
    /// an agent that has just written something, not a poll, so the wasted re-render is the
    /// rare case — while the no-op's cost was the operator reading a page that is simply
    /// wrong, with nothing anywhere saying so.
    ///
    /// **`open` is deliberately left alone.** The operator's own ⌘-click on an already-open
    /// artifact selects that pane and brings it forward, which puts them in front of it and
    /// lets them ask for a reload; nobody is in front of a push by construction.
    @discardableResult
    func offer(_: LocalBenchKey, _ source: CanvasSource) -> Pane.ID? {
        guard var bench else { return nil }
        let pane = bench.offer(canvas: source)
        if self.bench?.pane(pane) == nil {
            commit(bench)
        } else {
            // Only a pane already resolved into a canvas has a render to refresh. One that has
            // not — a restored tab nobody has selected since launch — reads the file when
            // `canvas(for:)` first builds its model, so resolving one here would buy nothing
            // and would open a `FileWatcher`, and its file descriptor, for a pane that is not
            // on screen.
            surfaces.existing(pane, as: CanvasModel.self)?.refresh()
        }
        return pane
    }

    /// `offer`, onto the bench of whichever workspace `path` names (#349).
    ///
    /// The mounted one is `offer` itself. A parked one is offered by its owner, `parked`, onto
    /// the bench stored for it, so the canvas is there when the operator switches in. The
    /// mounted bench is never touched by a parked workspace's push: that is the reason the
    /// workspace travels on the verb at all.
    ///
    /// A re-push of a canvas already on a parked bench refreshes its cached model when there is
    /// one. The cache survives a switch (`closeWorkspace`'s header), so a pane the operator has
    /// looked at still has a render, and #261's reason to refresh it holds unchanged.
    func offer(
        _ key: LocalBenchKey, _ source: CanvasSource, onBenchOf path: WorkspacePath
    )
        -> Pane.ID?
    {
        if path == workspacePath { return offer(key, source) }
        guard let pane = parked?.offer(source, toBenchOf: path) else { return nil }
        surfaces.existing(pane, as: CanvasModel.self)?.refresh()
        return pane
    }

    func close(_: LocalBenchKey, _ pane: Pane.ID) {
        guard var bench, bench.close(pane) else { return }
        // The offer goes with the pane it was about. Nothing else would drop it — an offer is
        // keyed by pane id, and a closed pane's id is one nothing resolves any more.
        resumeOffers[pane] = nil
        commit(bench)
        origins[pane] = nil
        // One teardown for every kind: the kind knows what letting its model go means.
        surfaces.close(pane)
    }

    func select(_: LocalBenchKey, _ pane: Pane.ID) {
        guard var bench else { return }
        bench.select(pane)
        commit(bench)
    }

    /// A tab click asked for **from outside** — the spool's `select` kind (#284), which is to
    /// `select(_:)` what `offerSplitRight()` is to `splitRight()`: the same selection with focus
    /// left where the operator put it (`Workbench.select(offering:)`).
    ///
    /// Reports whether the pane is **visible** afterwards rather than whether it was asked for,
    /// for `WorkbenchSpoolPanes.close`'s reason: the spool's result must say what the bench did,
    /// and "I asked" is not that.
    @discardableResult
    func offerSelect(_: LocalBenchKey, _ pane: Pane.ID) -> Bool {
        guard var bench, bench.pane(pane) != nil else { return false }
        bench.select(offering: pane)
        commit(bench)
        return self.bench?.visiblePaneIDs.contains(pane) ?? false
    }

    /// Call a pane something (#313), and report what it was called before — nil when this bench
    /// has no such pane.
    ///
    /// **No offering twin, for `Workbench.name`'s reason**: a name moves nothing, so the
    /// operator's version and an agent's would be the same mutation.
    ///
    /// **The bench is where the name lives; the session is a copy for rendering.** `commit` pushes
    /// it onto the session (`reconcileSessions`), which is what puts a *terminal's* name on its
    /// tab, in its notifications and — through `TerminalSession.displayTitle` —  in
    /// `snapshot.json`. A **canvas** has no session, so its name reaches its tab straight off the
    /// pane (`SlotTabStrip`) and reaches `snapshot.json` not at all: `BenchSnapshot.CanvasRecord`
    /// carries only a source. That is a real limit rather than a hedge, and `helm-name`'s own help
    /// text says so, because a caller reads the name back out of its result either way.
    @discardableResult
    func name(_: LocalBenchKey, _ pane: Pane.ID, to name: PaneName) -> PaneName? {
        guard var bench else { return nil }
        guard let previous = bench.name(pane, to: name) else { return nil }
        commit(bench)
        return previous
    }

    /// Make a slot the one commands target.
    ///
    /// **A slot that is already focused commits nothing**, and that guard is load-bearing now
    /// rather than tidy. Every click on a pane's body reaches here (#152), and `commit` runs
    /// `reconcileSessions` and drives `WorkspaceModel.observe`'s save — so without it, typing
    /// in the pane you are already in would write the whole workspace context to `UserDefaults`
    /// on every click. It also settles the feedback question: a no-op commit would re-render the
    /// bench, and re-renders are what `FocusClaimingTerminalView`'s edge-triggered claim exists
    /// to survive.
    func focus(_: LocalBenchKey, _ slot: Slot.ID) {
        guard var bench, bench.focusedSlot != slot else { return }
        bench.focus(slot)
        commit(bench)
    }

    @discardableResult
    func splitRight(_: LocalBenchKey) -> TerminalSession? {
        guard let path = workspacePath, var bench else { return nil }
        let session = terminals.newTerminal(in: path)
        bench.splitRight(with: Pane(id: session.id, content: .terminal()))
        commit(bench)
        return session
    }

    @discardableResult
    func splitDown(_: LocalBenchKey) -> TerminalSession? {
        guard let path = workspacePath, var bench else { return nil }
        let session = terminals.newTerminal(in: path)
        bench.splitDown(with: Pane(id: session.id, content: .terminal()))
        commit(bench)
        return session
    }

    /// ⌘D asked for **from outside** — the spool's `command` kind (#269), which is to
    /// `splitRight()` what `spawnTerminal()` is to `newTerminal()`: the same split with focus
    /// left where the operator put it (`Workbench.splitRight(offering:)`).
    ///
    /// Returns the session for the same reason the two spawning methods do — the spool has to
    /// report the new pane's id in `results/<id>.json`, so the caller's next move
    /// (`helm-close`, or a spawn into it) needs no lookup.
    @discardableResult
    func offerSplitRight(_: LocalBenchKey) -> TerminalSession? {
        guard let path = workspacePath, var bench else { return nil }
        let session = terminals.newTerminal(in: path)
        bench.splitRight(offering: Pane(id: session.id, content: .terminal()))
        commit(bench)
        return session
    }

    /// ⌘⇧D asked for from outside. See `offerSplitRight`.
    @discardableResult
    func offerSplitDown(_: LocalBenchKey) -> TerminalSession? {
        guard let path = workspacePath, var bench else { return nil }
        let session = terminals.newTerminal(in: path)
        bench.splitDown(offering: Pane(id: session.id, content: .terminal()))
        commit(bench)
        return session
    }

    /// A divider was dragged, and `neighbour` is the member on its other side.
    ///
    /// Sizes are helm's own state because `SplitStack` lays the bench out itself: AppKit's
    /// split views have no divider API to persist instead, and ignore the ideal sizes that
    /// were meant to stand in for one (#90). Nothing but a drag reaches here now — the
    /// mount-time measurement that used to is gone.
    func resizeColumn(
        _: LocalBenchKey, _ column: Column.ID, to fraction: Double, against neighbour: Column.ID
    ) {
        guard var bench else { return }
        bench.resizeColumn(column, to: fraction, against: neighbour)
        mount = .mounted(bench)
    }

    func resizeSlot(
        _: LocalBenchKey, _ slot: Slot.ID, to fraction: Double, against neighbour: Slot.ID
    ) {
        guard var bench else { return }
        bench.resizeSlot(slot, to: fraction, against: neighbour)
        mount = .mounted(bench)
    }

    func moveFocus(_: LocalBenchKey, _ direction: Workbench.Direction) {
        guard var bench else { return }
        bench.moveFocus(direction)
        commit(bench)
    }

    /// ⌘⌥⇧+arrow reaches here as `pane/move` on the focused pane (`VerbTemplate.moveFocused`),
    /// and everything else is `Workbench.move(_:_:)`'s, which is addressed so that a second
    /// caller can mean a different pane (#287). `commit` rather than a bare assignment because a
    /// move changes which panes are on screen: a relocated slot can be the only thing a column
    /// had.
    func move(_: LocalBenchKey, _ pane: Pane.ID, _ direction: Workbench.Direction) {
        guard var bench else { return }
        bench.move(pane, direction)
        commit(bench)
    }

    /// Write every open draft now (#289).
    ///
    /// **Named rather than written twice, because the two callers are unrelated**: a workspace
    /// teardown that is about to drop these models, and the app being quit. Both are moments
    /// after which a debounced save can no longer happen, and neither knows about the other.
    func flushNotes() {
        for canvas in surfaces.models(CanvasModel.self) { canvas.saveDraft() }
    }

    /// Which agent is in a terminal pane (#63), recorded on the bench so a restart can offer it.
    func record(_: LocalBenchKey, _ agent: ResumableAgent?, in pane: Pane.ID) {
        guard var bench else { return }
        bench.record(agent, in: pane)
        guard bench != self.bench else { return }
        commit(bench)
    }

    // MARK: - Visibility

    /// One assignment, then everything the change implies.
    private func commit(_ updated: Workbench) {
        mount = .mounted(updated)
        reconcileSessions()
    }

    /// Push what a session cannot know for itself onto every session in the app: `isVisible`,
    /// and — since #313 — the pane's name.
    ///
    /// On **every** bench change, not just on select: a close, a split or a focus move can
    /// all change which panes are on screen. Sessions in parked workspaces are invisible by
    /// definition, which is why this walks every session rather than only this workspace's.
    ///
    /// **The name is pushed here rather than handed to the tab view, and that is what makes
    /// there be one answer to "what is this pane called" (#313).** `TerminalSession.displayTitle`
    /// is spent by three readers — the tab, `TerminalNotifier`, and `BenchSnapshot.TerminalRecord`
    /// — so a name the *view* knew about would have left `snapshot.json` reporting the OSC title
    /// while the tab beside it read something else. It is the same shape as `isVisible` for the
    /// same reason: a fact that belongs to the bench, about a session that has no way to ask.
    ///
    /// **A parked workspace's sessions keep the name they were last pushed**, which is correct
    /// rather than stale: their panes are not on this bench, and nothing can rename them while
    /// they are off it (`WorkbenchSpoolPanes.pane` reads the mounted bench and answers nil for
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

extension WorkbenchModel: VerbSink {
    /// Every change to this bench, from anyone. See `VerbSink`.
    @discardableResult
    func send(_ verb: BenchVerb, by actor: BenchActor, asked: Bool) -> Pane.ID? {
        sink.send(verb, by: actor, asked: asked)
    }

    /// An agent's `push.sh` (#125): the canvas is offered as a `pane/open` from that agent, and
    /// the terminal it came from is remembered so a mark the operator later makes on the canvas
    /// can be mailed back to it (#205).
    ///
    /// **Recorded whether the pane is new or already open, and the second case is the common
    /// one** — an agent re-offering the file it just rewrote gets the pane that was there, and
    /// the newest pusher is the one who wants to hear about a mark on it. For a parked bench too:
    /// `origins` is keyed by pane id and survives a switch, and `deliver` resolves the origin
    /// against every workspace's sessions.
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
        origins[pane] = PushedBy(origin: origin, workspacePath: workspace)
        return pane
    }

    /// A ⌘-clicked http address (#376): the address becomes a new tab of the shared browser, in
    /// the background. helm opens the browser pane itself rather than as the operator's gesture,
    /// so it lands where the placement rules send it without taking the keyboard from the
    /// terminal clicked in: in daemon mode the browser drawer, which it badges (#356).
    func openLink(_ link: URL) {
        guard let id = send(.paneOpen(surface: .browser), by: .helm) else { return }
        browser(for: Pane(id: id, content: .browser)).open(link)
    }
}

// MARK: - Drawn from benchd (#354)

/// In an extension rather than the class body, which is already over its size limit (#418).
extension WorkbenchModel {

    /// Draw the bench from benchd's document, in daemon mode. Every change reaches the screen
    /// this way — the operator's key and an agent's verb alike — and nothing else writes `mount`.
    ///
    /// **What helm keeps for itself is the live objects**, reconciled against the document:
    /// a pane in no workspace any more has its object closed through its kind, and a terminal
    /// that appears while helm runs gets its shell wherever it landed, so a spawn into a
    /// background workspace is running before anyone looks. A terminal that was already in the
    /// document when helm started gets its shell when its workspace is first shown, as on
    /// restore (lazy on visit).
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
        if let known = knownPanes {
            for (path, arrived) in document.terminals(arrivedSince: known) {
                terminals.adopt(terminals: arrived, in: path, active: false)
            }
        }
        knownPanes = document.workspacePaneIDs

        let drawing = BenchDrawing.of(document, answered: answered)
        workspacePath = drawing.workspace
        shelvedBench = drawing.shelved
        mount = drawing.mount
        if let active = drawing.workspace, let bench = drawing.mount.bench {
            let firstVisit = answered.insert(active).inserted
            terminals.adopt(terminals: bench.terminalPaneIDs, in: active, active: true)
            if firstVisit { resumeOffers = offers(in: bench) }
        } else if drawing.workspace == nil {
            terminals.deactivate()
        } else {
            resumeOffers = [:]
        }
        reconcileSessions()
        documentFollower?(document)
    }

    /// #85's answer in daemon mode. Restoring draws what benchd already holds, bringing the shelf
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

    /// A divider drag. In local mode every step is a `layout/resize`, as it always was. In daemon
    /// mode the drag is drawn here as it moves and benchd hears once, on release: a round trip
    /// per mouse event would be a hundred events in the log for one gesture.
    func resize(_ divider: BenchDivider, to fraction: Double, released: Bool) {
        guard mode.client != nil else {
            // The release repeats the last step's fraction, and locally that step already landed.
            if !released { send(.layoutResize(divider, fraction: fraction), by: .operatorGesture) }
            return
        }
        guard !released else {
            send(.layoutResize(divider, fraction: fraction), by: .operatorGesture)
            return
        }
        guard var bench else { return }
        switch divider {
        case let .columns(member, against):
            bench.resizeColumn(member, to: fraction, against: against)
        case let .slots(member, against): bench.resizeSlot(member, to: fraction, against: against)
        }
        mount = .mounted(bench)
    }

    /// Say why a verb did not happen (daemon mode). A refusal is benchd's own sentence.
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
