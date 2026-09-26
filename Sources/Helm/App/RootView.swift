import HelmWire
import Inject
import SwiftUI

/// helm's permanent frame: the workspace bar above the workbench, the status bar below it.
///
/// **Composition only.** What is here touches two or more verticals at once: the workspace list
/// follows the document the bench is drawn from, a key's action needs every owner it might touch
/// (`LocalActions`), and the spool's adapters need the bench and the rail. Anything that can
/// name a single vertical belongs in that vertical's slice.
struct RootView: View {
    @ObserveInjection private var inject
    @StateObject private var model = WorkspaceModel()
    /// A `@StateObject` rather than a `.shared`: `TerminalManager.shared` and
    /// `BoardModel.shared` are singletons because other slices reach them, and nothing
    /// outside the workbench reaches this one. Drawn from benchd's document (#354).
    @StateObject private var workbench = WorkbenchModel(terminals: .shared, client: .live())
    @StateObject private var archonRail = ArchonRailModel()
    /// The operator's just runs (#356): started by his keys, failures shown on the status bar.
    @StateObject private var justRuns = JustRuns()
    /// #54's watcher. A `@StateObject` here rather than a `.shared` for the same reason the
    /// bench is: a second window gets its own, and the claim-by-rename in `SpoolDirectory` is
    /// what stops two of them acting on one request — the same mechanism that already has to
    /// hold between two helm *processes*.
    @StateObject private var spool = SpoolModel()
    @StateObject private var benchSnapshot = BenchSnapshotModel()
    @ObservedObject private var terminalManager = TerminalManager.shared
    /// What a key, a menu item or a button asks for is carried out here (`Actions`). Held so
    /// `Actions.performer`, which is weak, has something to point at.
    @State private var actions: LocalActions?

    init(benchSnapshot: BenchSnapshotModel = BenchSnapshotModel()) {
        _benchSnapshot = StateObject(wrappedValue: benchSnapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            // A tab click and a tab's Close are the operator's workspace verbs, sent through the
            // bench's one door like every other gesture.
            WorkspaceBar(
                model: model,
                select: {
                    workbench.send(.workspaceActivate(path: $0.path.value), by: .operatorGesture)
                },
                close: {
                    workbench.send(.workspaceClose(path: $0.path.value), by: .operatorGesture)
                })
            HStack(spacing: 0) {
                WorkbenchView(
                    model: workbench, workspaceRoot: model.selectedWorkspaceRoot?.value)
                if archonRail.isVisible {
                    Color.border.frame(width: 1)
                    ArchonRailView(
                        model: archonRail, workspacePath: model.selectedWorkspaceRoot)
                }
            }
            // Over the bench and the rail, never beside them: a drawer changes nothing under it.
            .overlay { DrawerHost(model: workbench, keymap: .shared) }
            StatusBarView(model: model, workbench: workbench, justRuns: justRuns)
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
            // benchd holds the workspaces and their benches; helm follows the document, after
            // moving the benches it used to save into an empty one once (`BenchImport`).
            workbench.followDocuments(
                BenchImport.follower(workspaces: model, workbench: workbench))
            // benchd's follower hears how a `just` run ended, and what benchd asks helm to do
            // (`bench get screenshot`, M3): helm draws its own window and answers.
            let asks = HelmAsks.answering(through: workbench.client, capturer: AppWindowCapturer())
            workbench.client.onEvent = { [justRuns] in
                justRuns.receive($0)
                asks.receive($0)
            }
            let actions = LocalActions(
                workbench: workbench, workspaces: model, rail: archonRail,
                terminals: terminalManager, just: justRuns)
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
            // The spool (#54) — the one seam an agent with no display can drive.
            spool.attach(
                spawner: WorkbenchSpoolSpawner(
                    workbench: workbench, terminals: terminalManager,
                    activate: workbench.openWorkspaceForSpawn))
            // #174's capturer. It needs nothing from this view — it resolves helm's window from
            // `NSApp` at capture time — so it is attached here only because this is where the
            // spool is wired, and a second seam for one line would be worse.
            spool.attach(capturer: AppWindowCapturer())
            // #176's teardown, #284's bring-forward and #313's naming — **one object, attached
            // three times**, because all three requests name a pane and are judged against the
            // same reading of it (`WorkbenchSpoolPanes`). Same two objects the spawner takes and
            // no `activate`: none of closing a pane, showing one or renaming one opens a
            // workspace, so it needs nothing from this view at all.
            let panes = WorkbenchSpoolPanes(workbench: workbench, terminals: terminalManager)
            spool.attach(closer: panes)
            spool.attach(selector: panes)
            spool.attach(namer: panes)
            // #269's driver. It takes the rail as well as the bench because `toggleRail` is the
            // one allowed command that touches neither a pane nor a pty — and both objects are
            // this view's `@StateObject`s, which is why the wiring is here with the rest.
            spool.attach(
                commander: WorkbenchSpoolCommander(workbench: workbench, rail: archonRail))
            spool.start()
        }
        .onDisappear { benchSnapshot.stop() }
        .enableInjection()
    }
}
