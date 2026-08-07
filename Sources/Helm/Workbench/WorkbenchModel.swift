import Combine
import Foundation
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
/// `TerminalWorkspace` got away with `@State` for the face because it was the one
/// always-present view; nothing under a bench is.
///
/// What is deliberately NOT here: a `ChatModel`. `ChatOverlay` owns its own as a
/// `@StateObject` driven from `.task`, so SwiftUI starts the 250 ms poll when the face
/// appears and cancels it when the face is swapped away. Caching one here the way canvases
/// are cached would turn a poller that runs only while someone is reading into one per
/// terminal pane, forever. The bench's only job is to say *which panes show the chat face*.
@MainActor
final class WorkbenchModel: ObservableObject {
    /// nil when no workspace is open. Not an "empty bench": `Workbench`'s first invariant
    /// is that a bench always holds at least one pane, so there is no such value to make.
    @Published private(set) var bench: Workbench?

    /// ⌘O's popover. App chrome rather than slot chrome — it appears once, on the focused
    /// slot's strip, because repeating it on every strip would multiply it by N. The
    /// *state* is here rather than in a view because the command that opens it is.
    @Published var isBrowserOpen = false

    private(set) var workspacePath: WorkspacePath?

    private let terminals: TerminalManager

    /// One `CanvasModel` per canvas pane, keyed by pane id — the "N instances" #23 named.
    /// Dropped when its pane closes, which drops its `FileWatcher` and that watcher's open
    /// file descriptor with it.
    ///
    /// **Stamped with the workspace that opened it**, for the same reason `TerminalSession`
    /// carries `workspacePath`: `closeWorkspace` has to drop what a workspace owned, and by
    /// the time it runs that workspace's bench is no longer the live one to ask. Without
    /// the stamp the cache had no way to answer "whose is this?" and the entries simply
    /// stayed — a `FileWatcher` and its open descriptor per canvas, for the life of the
    /// process.
    private var canvases: [Pane.ID: CachedCanvas] = [:]

    private struct CachedCanvas {
        let workspacePath: WorkspacePath?
        let model: CanvasModel
    }

    /// Which terminal put each canvas pane on the bench (#205) — the key is the **canvas** pane,
    /// the value names the **terminal** pane, which is what `CanvasOrigin` exists to keep straight.
    ///
    /// Kept beside `canvases` rather than on `Pane.Content.canvas`, and that is load-bearing:
    /// `CanvasSource` is compared by value to answer "is this file already open?"
    /// (`Workbench.pane(showing:)`), so an origin inside it would make the same artifact pushed by
    /// two agents two different sources — a second pane for a file already on screen, which is the
    /// interruption `offer` exists to avoid. It also must not persist; `CanvasOrigin`'s header has
    /// the reason.
    private var origins: [Pane.ID: CanvasOrigin] = [:]

    /// How a mark leaves helm. Injected for the same reason `BenchSnapshotModel` injects its
    /// mailbox root and its `foregroundPid`: the routing is then reachable from `swift test`
    /// against a mailbox the test owns, with no live agent and nothing written near the
    /// operator's own `~/.helm/mail`.
    private let notes: CanvasNoteCourier

    /// `AnyCancellable`s rather than NotificationCenter tokens: they unsubscribe in their
    /// own deinit, and Swift 6 forbids a nonisolated deinit from touching the non-Sendable
    /// token the observer API hands back.
    private var commands: Set<AnyCancellable> = []

    /// Internal, not a `.shared`. `TerminalManager.shared` and `BoardModel.shared` are
    /// singletons because other slices reach them; nothing outside the workbench needs
    /// this one, and an injectable initialiser is what lets tests build isolated models.
    init(terminals: TerminalManager, notes: CanvasNoteCourier = CanvasNoteCourier()) {
        self.terminals = terminals
        self.notes = notes
        subscribe()
    }

    // MARK: - Lifecycle

    /// Makes a workspace's bench the live one. Lazy on first visit, exactly like
    /// `TerminalManager.activate`, and for the same reason: nothing spawns a pty until the
    /// workspace is actually visited.
    ///
    /// `restoring` is the persisted bench — or the one `migrating(from:)` built out of a
    /// pre-bench context. Its terminal pane ids ARE session ids, so they go straight to
    /// `TerminalManager.activate(restoring:)` and the row comes back under them.
    func activate(workspacePath path: WorkspacePath, restoring restorable: Workbench? = nil) {
        workspacePath = path
        terminals.activate(workspacePath: path, restoring: restorable?.terminalPaneIDs ?? [])
        // The manager is the authority on which terminals exist — it may have just made a
        // fresh shell for a workspace with nothing persisted, and that shell's id is not
        // in any restored bench.
        let live = terminals.sessions(for: path).map(\.id)
        bench = restorable ?? Self.defaultBench(for: live)
        reconcileVisibility()
    }

    func deactivate() {
        workspacePath = nil
        bench = nil
        canvases.removeAll()
        // Keyed by canvas pane id, so it goes exactly when the cache does — a leftover entry
        // would name a pane nothing resolves any more.
        origins.removeAll()
        reconcileVisibility()
    }

    /// Closing a workspace is an explicit teardown, unlike switching: drop every canvas it
    /// owned so each `FileWatcher` — and that watcher's open file descriptor — goes with
    /// it. The bench's twin of `TerminalManager.closeWorkspace`, and called the same way:
    /// unconditionally, naming the workspace, whether or not it is the active one.
    ///
    /// **Deliberately not done on a workspace SWITCH.** The cache surviving a switch is
    /// what gets the same webview back instead of a reload, and pane ids are persisted, so
    /// switching back finds its canvases still there. `activate` is right to leave it
    /// alone; only closing is a teardown.
    func closeWorkspace(_ path: WorkspacePath) {
        for (id, cached) in canvases where cached.workspacePath == path {
            cached.model.close()
            canvases[id] = nil
            origins[id] = nil
        }
    }

    /// Today's frame, built out of whatever sessions the manager has: one column, one
    /// slot, the terminals as tabs. nil only when there are none, which
    /// `TerminalManager.activate` does not leave behind.
    private static func defaultBench(for sessions: [Pane.ID]) -> Workbench? {
        guard !sessions.isEmpty else { return nil }
        return Workbench(panes: sessions.map { Pane(id: $0, content: .terminal(face: .terminal)) })
    }

    // MARK: - Resolving panes to the objects they name

    func session(for pane: Pane) -> TerminalSession? {
        guard case .terminal = pane.content else { return nil }
        return terminals.sessions.first { $0.id == pane.id }
    }

    /// Resolve-or-create, at the edge. The model is cached by pane id so a tab switch or a
    /// re-render gets the same webview back rather than reloading the page.
    func canvas(for pane: Pane) -> CanvasModel {
        if let existing = canvases[pane.id] { return existing.model }
        let model = CanvasModel(
            source: {
                if case let .canvas(source) = pane.content { source } else { nil }
            }())
        // The other direction, and the half that was missing: a canvas that goes somewhere
        // has to take its pane with it, or the bench persists where the pane *started*
        // (#89). Wired here because this is the only place a `CanvasModel` is made — and
        // wired AFTER construction on purpose, so resolving a restored pane into its own
        // canvas is not mistaken for that canvas moving.
        //
        // The identity check is what keeps an ORPHAN quiet. `deactivate` drops the cache
        // without closing what is in it, so a model whose pane was re-resolved afterwards is
        // still alive, still holding this closure, and still able to report — into a bench
        // that now resolves that pane to a different canvas. `model` is captured weakly
        // because the closure is stored on it; it is always there when the closure runs.
        model.onSourceChange = { [weak self, weak model] source in
            guard let self, let model, canvases[pane.id]?.model === model else { return }
            canvas(pane.id, didPointAt: source)
        }
        // The return path (#205). Wired here for `onSourceChange`'s reasons exactly — this is the
        // only place a `CanvasModel` is made, and the identity check keeps an orphan quiet: a
        // model whose pane was re-resolved after `deactivate` is still alive and still holding
        // this closure, and it has no origin to route to any more.
        model.onAnnotation = { [weak self, weak model] annotation, canvas in
            guard let self, let model, canvases[pane.id]?.model === model else {
                return .notSent(.noOrigin)
            }
            return deliver(annotation, on: canvas, markedIn: pane.id)
        }
        // A canvas pane only renders while its workspace is the active one, so this is
        // that workspace — the same association `TerminalManager` gets for free by
        // storing `workspacePath` on the session itself.
        canvases[pane.id] = CachedCanvas(workspacePath: workspacePath, model: model)
        return model
    }

    /// Record where a canvas is pointed now. The rule for what may be repointed is
    /// `Workbench.repoint(_:to:)`'s; what is decided here is **when it is worth committing**.
    ///
    /// Only a real move. `CanvasModel.source` is unchanged by a reload, by a load failure,
    /// and by an address the policy refuses — and every commit reaches `UserDefaults`,
    /// because `WorkspaceModel.observe` saves on each bench change. The pane is looked up
    /// each time rather than captured, so a canvas that outlives its pane by a moment
    /// repoints nothing.
    ///
    /// **Only this workspace's bench**, because that is the only one there is: a parked
    /// workspace's arrangement is a value in `WorkspaceModel.contexts` and nothing can
    /// mutate it until it is activated again. A canvas belonging to one reports into a
    /// bench that does not hold its pane and is dropped here — which is reachable only if a
    /// webview outlives the teardown of the view that owned it, since a parked pane has no
    /// webview left to navigate.
    private func canvas(_ pane: Pane.ID, didPointAt source: CanvasSource) {
        guard var bench, let target = bench.pane(pane),
            case let .canvas(current) = target.content, current != source
        else { return }
        bench.repoint(pane, to: source)
        commit(bench)
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
            notes.owner(of: terminals.sessions.first { $0.id == origin.terminal })
        }
        return notes.send(annotation, on: canvas, along: route)
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
    func newTerminal() -> TerminalSession? {
        guard let path = workspacePath, var bench else { return nil }
        let session = terminals.newTerminal(in: path)
        bench.insert(
            Pane(id: session.id, content: .terminal(face: .terminal)),
            at: bench.placementForNewTerminal())
        commit(bench)
        return session
    }

    /// A terminal helm was asked to open **from outside** — the spool's spawn (#54), which is
    /// the same tenant `newTerminal` makes and two different decisions about it.
    ///
    /// Where it lands is `Workbench.placementForSpawnedTerminal()`'s — a pane of its own,
    /// decided by the bench rather than by whatever the operator last clicked. That it
    /// *appears* rather than seizing is `Workbench.offer(_:at:)`'s (#125): `selected` and
    /// `focusedSlot` are both left exactly as they were, so the keyboard stays in the pane
    /// the operator is typing in. A spawn nobody asked for that takes the keyboard is worse
    /// than one in an odd slot.
    ///
    /// Returns the session for the same reason `newTerminal` does: the spool has to write
    /// its id into `results/<id>.json` and then send the launch line to that exact pane.
    @discardableResult
    func spawnTerminal() -> TerminalSession? {
        guard let path = workspacePath, var bench else { return nil }
        let session = terminals.newTerminal(in: path)
        bench.offer(
            Pane(id: session.id, content: .terminal(face: .terminal)),
            at: bench.placementForSpawnedTerminal())
        commit(bench)
        return session
    }

    /// Where an offered canvas lands is `Workbench.placement(forOpening:)`'s decision, not
    /// this method's. Returns the pane actually showing the source — which for an
    /// already-open one is the pane that was there, not a second copy.
    @discardableResult
    func open(_ source: CanvasSource) -> Pane.ID? {
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
    func offer(_ source: CanvasSource) -> Pane.ID? {
        guard var bench else { return nil }
        let placement = bench.placement(forOpening: source)
        if case let .existing(open) = placement {
            // Only a pane already resolved into a canvas has a render to refresh. One that has
            // not — a restored tab nobody has selected since launch — reads the file when
            // `canvas(for:)` first builds its model, so resolving one here would buy nothing
            // and would open a `FileWatcher`, and its file descriptor, for a pane that is not
            // on screen.
            canvases[open]?.model.refresh()
            return open
        }
        let pane = Pane(content: .canvas(source))
        bench.offer(pane, at: placement)
        commit(bench)
        return pane.id
    }

    func close(_ pane: Pane.ID) {
        guard var bench, let closing = bench.pane(pane), bench.close(pane) else { return }
        commit(bench)
        switch closing.content {
        case .terminal:
            // Dropping the manager's last strong reference is what actually kills the pty.
            if let session = terminals.sessions.first(where: { $0.id == pane }) {
                terminals.close(session)
            }
        case .canvas:
            canvases[pane]?.model.close()
            canvases[pane] = nil
            origins[pane] = nil
        }
    }

    func select(_ pane: Pane.ID) {
        guard var bench else { return }
        bench.select(pane)
        commit(bench)
    }

    /// ⌘1–⌘9 — select by position **within the focused slot**. It was by position within
    /// the workspace; a bench has no single row for that to mean.
    func selectTab(_ index: Int) {
        guard let bench, let slot = bench.slot(bench.focusedSlot),
            slot.panes.indices.contains(index)
        else { return }
        select(slot.panes[index].id)
    }

    /// Make a slot the one commands target.
    ///
    /// **A slot that is already focused commits nothing**, and that guard is load-bearing now
    /// rather than tidy. Every click on a pane's body reaches here (#152), and `commit` runs
    /// `reconcileVisibility` and drives `WorkspaceModel.observe`'s save — so without it, typing
    /// in the pane you are already in would write the whole workspace context to `UserDefaults`
    /// on every click. It also settles the feedback question: a no-op commit would re-render the
    /// bench, and re-renders are what `FocusClaimingTerminalView`'s edge-triggered claim exists
    /// to survive.
    func focus(_ slot: Slot.ID) {
        guard var bench, bench.focusedSlot != slot else { return }
        bench.focus(slot)
        commit(bench)
    }

    func splitRight() {
        guard let path = workspacePath, var bench else { return }
        bench.splitRight(
            with: Pane(id: terminals.newTerminal(in: path).id, content: .terminal(face: .terminal)))
        commit(bench)
    }

    func splitDown() {
        guard let path = workspacePath, var bench else { return }
        bench.splitDown(
            with: Pane(id: terminals.newTerminal(in: path).id, content: .terminal(face: .terminal)))
        commit(bench)
    }

    /// ⌘D asked for **from outside** — the spool's `command` kind (#269), which is to
    /// `splitRight()` what `spawnTerminal()` is to `newTerminal()`: the same split with focus
    /// left where the operator put it (`Workbench.splitRight(offering:)`).
    ///
    /// Returns the session for the same reason the two spawning methods do — the spool has to
    /// report the new pane's id in `results/<id>.json`, so the caller's next move
    /// (`helm-close`, or a spawn into it) needs no lookup.
    @discardableResult
    func offerSplitRight() -> TerminalSession? {
        guard let path = workspacePath, var bench else { return nil }
        let session = terminals.newTerminal(in: path)
        bench.splitRight(offering: Pane(id: session.id, content: .terminal(face: .terminal)))
        commit(bench)
        return session
    }

    /// ⌘⇧D asked for from outside. See `offerSplitRight`.
    @discardableResult
    func offerSplitDown() -> TerminalSession? {
        guard let path = workspacePath, var bench else { return nil }
        let session = terminals.newTerminal(in: path)
        bench.splitDown(offering: Pane(id: session.id, content: .terminal(face: .terminal)))
        commit(bench)
        return session
    }

    /// A divider was dragged, and `neighbour` is the member on its other side.
    ///
    /// Sizes are helm's own state because `SplitStack` lays the bench out itself: AppKit's
    /// split views have no divider API to persist instead, and ignore the ideal sizes that
    /// were meant to stand in for one (#90). Nothing but a drag reaches here now — the
    /// mount-time measurement that used to is gone.
    func resizeColumn(_ column: Column.ID, to fraction: Double, against neighbour: Column.ID) {
        guard var bench else { return }
        bench.resizeColumn(column, to: fraction, against: neighbour)
        self.bench = bench
    }

    func resizeSlot(_ slot: Slot.ID, to fraction: Double, against neighbour: Slot.ID) {
        guard var bench else { return }
        bench.resizeSlot(slot, to: fraction, against: neighbour)
        self.bench = bench
    }

    func moveFocus(_ direction: Workbench.Direction) {
        guard var bench else { return }
        bench.moveFocus(direction)
        commit(bench)
    }

    /// ⌘⌥⇧+arrow. **The only decision here is which pane the keystroke meant** — the focused one
    /// — and everything else is `Workbench.move(_:_:)`'s, which is addressed precisely so that a
    /// second caller can mean a different pane (#287). `commit` rather than a bare assignment
    /// because a move changes which panes are on screen: a relocated slot can be the only thing
    /// a column had.
    func movePane(_ direction: Workbench.Direction) {
        guard var bench, let pane = bench.focusedPane?.id else { return }
        bench.move(pane, direction)
        commit(bench)
    }

    /// ⌘T. The rule — including that it does nothing at all on a canvas — is
    /// `Workbench.toggleFace()`'s, so this is a delegation and not a decision.
    func toggleFace() {
        guard var bench else { return }
        bench.toggleFace()
        commit(bench)
    }

    /// Hand a canvas's accumulated notes to a composer, if there is one to hand them to.
    ///
    /// **Post inherits the composer's gate rather than adding one of its own.** Prefilling
    /// only fills the field — `ChatModel.canSend` (`status == .idle`, nothing looser) is
    /// what decides whether it can be sent, and #29 measured why that must not be relaxed.
    func post(_ text: String) {
        guard let pane = composeTarget else { return }
        HelmCommand.composeText(ComposeRequest(pane: pane, text: text)).post()
    }

    /// The pane whose composer a `Post` reaches: the focused pane if it is a terminal on
    /// the chat face, else the only chat face open. nil when there is no unambiguous
    /// target — and then the button is disabled rather than posting into nothing, because
    /// a control that silently does nothing is worse than one that says it cannot.
    var composeTarget: Pane.ID? {
        guard let bench else { return nil }
        if let focused = bench.focusedPane, case .terminal(.chat) = focused.content {
            return focused.id
        }
        let reading = bench.panes.filter {
            if case .terminal(.chat) = $0.content { true } else { false }
        }
        return reading.count == 1 ? reading[0].id : nil
    }

    func closeFocusedPane() {
        guard let pane = bench?.focusedPane else { return }
        close(pane.id)
    }

    // MARK: - Visibility

    /// One assignment, then everything the change implies.
    private func commit(_ updated: Workbench) {
        bench = updated
        reconcileVisibility()
    }

    /// Push `isVisible` onto every session in the app.
    ///
    /// On **every** bench change, not just on select: a close, a split or a focus move can
    /// all change which panes are on screen. Sessions in parked workspaces are invisible by
    /// definition, which is why this walks every session rather than only this workspace's.
    ///
    /// It does nothing else. An earlier draft of this plan had it keep one `hostView`
    /// attached at 1×1pt in case zero attached ghostty surfaces stalled every pty — that
    /// was measured and it does not: a backgrounded pty ran a delayed command to completion
    /// with every surface unmounted. Do not reintroduce it from reading
    /// `TerminalSession`'s header, which predicts the opposite and is wrong about this.
    private func reconcileVisibility() {
        let visible = bench?.visiblePaneIDs ?? []
        for session in terminals.sessions {
            session.isVisible =
                session.workspacePath == workspacePath && visible.contains(session.id)
        }
    }

    // MARK: - Subscriptions

    /// **One subscription, and the `switch` is exhaustive.** This was twelve, each unpacking
    /// `Notification.object` with its own `as?` — seven of them, four re-parsing an enum from a
    /// raw value the poster had flattened it into. A command this bench does not handle is now
    /// `default`, named and deliberate, rather than a name nobody happened to subscribe to.
    private func subscribe() {
        HelmCommand.publisher
            // Load-bearing, not decoration: `@Published` fires in `willSet`, so a handler
            // that re-reads state synchronously would see the value from before the change.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] command in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.handle(command)
                }
            }
            .store(in: &commands)
    }

    private func handle(_ command: HelmCommand) {
        switch command {
        case .newTerminal: newTerminal()
        case let .selectTerminal(index): selectTab(index)
        case .openArtifact: isBrowserOpen.toggle()
        case let .adjustFontSize(step): focusedTerminal?.adjustFontSize(step)
        case let .jumpToPrompt(offset):
            guard terminals.anyTerminalHasFocus else { return }
            focusedTerminal?.jumpToPrompt(by: offset)
        case .toggleChat: toggleFace()
        case .splitRight: splitRight()
        case .splitDown: splitDown()
        case .closePane: closeFocusedPane()
        case let .moveFocus(direction): moveFocus(direction)
        case let .movePane(direction): movePane(direction)
        case let .openCanvasFile(url): open(.file(url))

        // Scoped to the workspace whose terminal asked. A push comes from OUTPUT, so it
        // can arrive from a session the operator parked long ago — and this model is the
        // active workspace's, whichever that now is.
        case let .pushCanvasFile(request):
            guard request.workspacePath == workspacePath else { return }
            // **Recorded whether the pane is new or already open, and the second case is the
            // common one** — an agent re-offering the file it just rewrote gets `.existing`, and
            // the newest pusher is the one who wants to hear about a mark on it.
            guard let pane = offer(.file(request.artifact)) else { return }
            origins[pane] = request.origin

        // ⌘L is `nil` and means "show me the address field"; a URL means "open this",
        // which is what a ⌘-clicked http link sends. The distinction is now in the type
        // rather than in whether an `Any?` happened to be absent.
        case let .openCanvasURL(url):
            if let url { open(.url(url)) } else { openAddressField() }

        // Belongs to other verticals: the workspace bar, the Archon rail, `RootView`, and
        // the chat overlay of one addressed pane. Listed rather than defaulted silently, so
        // adding a command forces a decision here instead of producing a no-op.
        case .openWorkspace, .toggleRail, .selectWorkspace, .cycleWorkspace, .composeText:
            break
        }
    }

    /// ⌘L. On a canvas already showing a page this is "edit this address" and keeps the
    /// page; otherwise it opens an empty canvas — placement decides where — with the field
    /// focused.
    private func openAddressField() {
        if let pane = bench?.focusedPane, case let .canvas(source) = pane.content,
            case .url = source
        {
            canvas(for: pane).focusAddress()
            return
        }
        guard let id = open(.empty), let pane = bench?.pane(id) else { return }
        canvas(for: pane).focusAddress()
    }
}
