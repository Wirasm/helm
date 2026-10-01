import HelmWire
import Inject
import SwiftUI

/// helm's permanent frame: the workspace bar above the workbench, the status bar below it.
///
/// **Composition only.** What is here touches two or more verticals at once: the workspace list
/// follows the document the bench is drawn from, a key's action needs every owner it might touch
/// (`LocalActions`), and benchd's asks need the client and the window. Anything that can
/// name a single vertical belongs in that vertical's slice.
struct RootView: View {
    @ObserveInjection private var inject
    @StateObject private var model: WorkspaceModel
    /// A `@StateObject` rather than a `.shared`: `TerminalManager.shared` and
    /// `BoardModel.shared` are singletons because other slices reach them, and nothing
    /// outside the workbench reaches this one. Drawn from benchd's document (#354).
    @StateObject private var workbench: WorkbenchModel
    /// The operator's just runs (#356): started by his keys, failures shown on the status bar.
    @StateObject private var justRuns = JustRuns()
    /// The command palette (#500): ⌘K opens it through `LocalActions`, the overlay draws it.
    @StateObject private var palette = CommandPalette()
    @ObservedObject private var keymap = Keymap.shared
    @StateObject private var benchSnapshot = BenchSnapshotModel()
    @ObservedObject private var terminalManager = TerminalManager.shared
    /// What a key, a menu item or a button asks for is carried out here (`Actions`). Held so
    /// `Actions.performer`, which is weak, has something to point at.
    @State private var actions: LocalActions?

    /// `client` is the benchd this window draws, and has no default: a window drawn from the
    /// operator's benchd starts `bench attach` for every visible terminal pane, and each attach
    /// takes that session from the pane showing it. A test that built this view with the live
    /// client did exactly that to the operator's panes.
    init(
        client: @escaping @autoclosure () -> BenchClient,
        benchSnapshot: BenchSnapshotModel = BenchSnapshotModel()
    ) {
        _workbench = StateObject(wrappedValue: WorkbenchModel(terminals: .shared, client: client()))
        // Each tab's branch is read on benchd's machine, where the workspace is. Built only when
        // SwiftUI first makes the model, like the workbench: this `init` runs on every redraw.
        _model = StateObject(
            wrappedValue: WorkspaceModel(host: BenchdHost(endpoint: client().endpoint)))
        _benchSnapshot = StateObject(wrappedValue: benchSnapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            // A tab click and a tab's Close are the operator's workspace verbs, sent through the
            // bench's one door like every other gesture.
            WorkspaceBar(
                model: model,
                workbench: workbench,
                select: {
                    workbench.send(.workspaceActivate(path: $0.path.value), by: .operatorGesture)
                },
                close: {
                    workbench.send(.workspaceClose(path: $0.path.value), by: .operatorGesture)
                }
            )
            // Above the bench, which it precedes: a zoomed bench (⌘J, `BenchCamera`) is laid out
            // past its own top edge, and a terminal there would otherwise take the bar's clicks.
            .zIndex(1)
            WorkbenchView(model: workbench, workspaceRoot: model.selectedWorkspaceRoot?.value)
                // Over the bench, never beside it: a drawer changes nothing under it.
                .overlay { DrawerHost(model: workbench, keymap: .shared) }
                // The keys available now, while the manage key is held (#499). Over the drawer
                // too: it answers "what can I press", wherever the keyboard is.
                .overlay { KeyPopup(keymap: .shared, hold: .shared) }
                .overlay {
                    CommandPaletteView(
                        palette: palette,
                        commands: CommandList.of(
                            table: keymap.table, document: workbench.document,
                            recipes: palette.recipes,
                            liveTitle: { CommandList.liveTitle(of: $0, in: workbench) }),
                        run: runCommand)
                }
                .onChange(of: palette.isOpen) { _, open in if !open { returnKeyboard() } }
            StatusBarView(model: model, workbench: workbench, justRuns: justRuns)
        }
        // One space for every drag (#178): the bar's tabs and the bench's slots report their frames
        // in it, so a pane's tab can be dropped on a workspace's and the drop zone is drawn exactly
        // where the views are (`BenchDrag`).
        .overlay(alignment: .topLeading) { DropZoneOverlay(drag: workbench.drag) }
        .coordinateSpace(name: BenchDrag.space)
        // ⇧⌘O: a folder on benchd's machine, checked there (M5c).
        .sheet(isPresented: $workbench.isWorkspacePickerOpen, onDismiss: returnKeyboard) {
            WorkspacePicker(prp: PrpStores(client: workbench.client)) { path in
                workbench.send(.workspaceOpen(path: path), by: .operatorGesture)
            } dismiss: {
                workbench.isWorkspacePickerOpen = false
            }
        }
        // The base plane, and it has to be painted: `translucentWindow` makes the window
        // non-opaque so the chrome's vibrancy has a desktop to sample, and anything that
        // paints nothing after that is a hole rather than a neutral grey. The terminal and
        // the canvas cover their own panes; this is everything else.
        .background(Color.surface)
        .translucentWindow()
        // A no-op unless `HELM_DEFAULTS_SUITE` is set (#86): stops an isolated instance
        // autosaving its frame over the operator's, which is the one write a suite cannot
        // catch because AppKit makes it rather than helm.
        .isolatedInstanceWindow()
        .task {
            // benchd holds the workspaces and their benches; helm follows the document.
            workbench.followDocuments { [weak model] in model?.follow($0) }
            // benchd's follower hears how a `just` run ended, and what benchd asks helm to do
            // (`bench get screenshot`, M3): helm draws its own window and answers.
            let asks = HelmAsks.answering(through: workbench.client, capturer: AppWindowCapturer())
            workbench.client.onEvent = { [justRuns, workbench] in
                justRuns.receive($0)
                asks.receive($0)
                // A canvas file changed on benchd's side (M5c): helm watches no file itself.
                workbench.fileChanged($0)
            }
            let actions = LocalActions(
                workbench: workbench, workspaces: model, terminals: terminalManager,
                just: justRuns, palette: palette)
            self.actions = actions
            Actions.performer = actions
            benchSnapshot.start(
                workspaces: model, workbench: workbench, terminals: terminalManager)
            // `--artifact <path>` (`LaunchOptions.artifactPath`) — a launch seam for
            // driving helm into a given state without keystroke injection. It opens into
            // whichever pane placement chooses, exactly like a ⌘-clicked link.
            if let path = LaunchOptions.artifactPath {
                workbench.send(
                    .paneOpen(surface: .canvas(path: (path as NSString).expandingTildeInPath)),
                    by: .operatorGesture)
            }
        }
        .onDisappear { benchSnapshot.stop() }
        .enableInjection()
    }

    /// A palette line, carried out through the doors a key uses.
    private func runCommand(_ run: Command.Run) {
        switch run {
        case let .action(action): Actions.perform(action)
        case let .verbs(verbs):
            for verb in verbs { workbench.send(verb, by: .operatorGesture) }
        }
    }

    /// The palette's field took the keyboard; however it closed (a line run, Esc, ⌘K again),
    /// the terminal holding focus gets it back. A verb that moves focus hands it on again when
    /// its document lands, through the terminal's own claim.
    private func returnKeyboard() {
        guard let view = workbench.focusedTerminal?.hostView, let window = view.window else {
            return
        }
        window.makeFirstResponder(view)
    }
}
