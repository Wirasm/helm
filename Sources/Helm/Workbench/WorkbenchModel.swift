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

    private(set) var workspacePath: String?

    private let terminals: TerminalManager

    /// One `CanvasModel` per canvas pane, keyed by pane id — the "N instances" #23 named.
    /// Dropped when its pane closes, which drops its `FileWatcher` and that watcher's open
    /// file descriptor with it.
    private var canvases: [Pane.ID: CanvasModel] = [:]

    /// `AnyCancellable`s rather than NotificationCenter tokens: they unsubscribe in their
    /// own deinit, and Swift 6 forbids a nonisolated deinit from touching the non-Sendable
    /// token the observer API hands back.
    private var commands: Set<AnyCancellable> = []

    /// Internal, not a `.shared`. `TerminalManager.shared` and `BoardModel.shared` are
    /// singletons because other slices reach them; nothing outside the workbench needs
    /// this one, and an injectable initialiser is what lets tests build isolated models.
    init(terminals: TerminalManager) {
        self.terminals = terminals
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
    func activate(workspacePath path: String, restoring restorable: Workbench? = nil) {
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
        reconcileVisibility()
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
        if let existing = canvases[pane.id] { return existing }
        let model = CanvasModel()
        if case let .canvas(source) = pane.content { model.show(source) }
        canvases[pane.id] = model
        return model
    }

    /// What ⌘+/⌘0/⌘↑ act on.
    var focusedTerminal: TerminalSession? {
        bench?.focusedPane.flatMap(session(for:))
    }

    // MARK: - Commands

    func newTerminal() {
        guard let path = workspacePath, var bench else { return }
        let session = terminals.newTerminal(in: path)
        bench.insert(
            Pane(id: session.id, content: .terminal(face: .terminal)),
            at: bench.placementForNewTerminal())
        commit(bench)
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
            canvases[pane]?.close()
            canvases[pane] = nil
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

    func focus(_ slot: Slot.ID) {
        guard var bench else { return }
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

    /// A divider was dragged. Sizes are helm's own state because `HSplitView` has no
    /// divider API to persist instead.
    func resizeColumn(_ column: Column.ID, to fraction: Double) {
        guard var bench else { return }
        bench.resizeColumn(column, to: fraction)
        self.bench = bench
    }

    func resizeSlot(_ slot: Slot.ID, to fraction: Double) {
        guard var bench else { return }
        bench.resizeSlot(slot, to: fraction)
        self.bench = bench
    }

    func moveFocus(_ direction: Workbench.Direction) {
        guard var bench else { return }
        bench.moveFocus(direction)
        commit(bench)
    }

    /// ⌘T. The rule — including that it does nothing at all on a canvas — is
    /// `Workbench.toggleFace()`'s, so this is a delegation and not a decision.
    func toggleFace() {
        guard var bench else { return }
        bench.toggleFace()
        commit(bench)
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

    private func subscribe() {
        subscribe(to: .helmNewTerminal) { model, _ in model.newTerminal() }
        subscribe(to: .helmSelectTerminal) { model, note in
            if let index = note.object as? Int { model.selectTab(index) }
        }
        subscribe(to: .helmOpenArtifact) { model, _ in model.isBrowserOpen.toggle() }
        subscribe(to: .helmAdjustFontSize) { model, note in
            guard let raw = note.object as? Int, let step = FontSizeStep(rawValue: raw) else {
                return
            }
            model.focusedTerminal?.adjustFontSize(step)
        }
        subscribe(to: .helmJumpToPrompt) { model, note in
            guard model.terminals.anyTerminalHasFocus, let offset = note.object as? Int
            else { return }
            model.focusedTerminal?.jumpToPrompt(by: offset)
        }
        subscribe(to: .helmToggleChat) { model, _ in model.toggleFace() }
        subscribe(to: .helmSplitRight) { model, _ in model.splitRight() }
        subscribe(to: .helmSplitDown) { model, _ in model.splitDown() }
        subscribe(to: .helmClosePane) { model, _ in model.closeFocusedPane() }
        subscribe(to: .helmMoveFocus) { model, note in
            guard let raw = note.object as? String,
                let direction = Workbench.Direction(rawValue: raw)
            else { return }
            model.moveFocus(direction)
        }
        subscribe(to: .helmOpenCanvasFile) { model, note in
            guard let url = note.object as? URL else { return }
            model.open(.file(url))
        }
        // ⌘L carries no payload and means "show me the address field"; a URL payload
        // means "open this", which is what a ⌘-clicked http link posts.
        subscribe(to: .helmOpenCanvasURL) { model, note in
            if let url = note.object as? URL {
                model.open(.url(url))
            } else {
                model.openAddressField()
            }
        }
    }

    private func subscribe(
        to name: Notification.Name, _ handler: @escaping (WorkbenchModel, Notification) -> Void
    ) {
        NotificationCenter.default
            .publisher(for: name)
            // Load-bearing, not decoration: `@Published` fires in `willSet`, so a handler
            // that re-reads state synchronously would see the value from before the change.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self, note)
                }
            }
            .store(in: &commands)
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
