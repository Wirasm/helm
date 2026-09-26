import HelmWire
import Inject
import SwiftUI

/// helm's permanent frame: the workspace bar above the workbench, the status bar below it.
///
/// **Composition only**, and more so than before. The canvas is no longer a special case
/// wired in here — it is a bench pane, so the dock's `HSplitView` and the single
/// `CanvasModel` are both gone. What is left here touches two or more verticals at once:
/// persisting a workspace's context needs the workspace and its bench together, switching
/// workspaces has to move both (`apply`, where the sink hands the workspace verbs), and a key's
/// action needs every owner it might touch (`LocalActions`). Anything that can name a single
/// vertical belongs in that vertical's slice.
struct RootView: View {
    @ObserveInjection private var inject
    @StateObject private var model = WorkspaceModel()
    /// A `@StateObject` rather than a `.shared`: `TerminalManager.shared` and
    /// `BoardModel.shared` are singletons because other slices reach them, and nothing
    /// outside the workbench reaches this one.
    /// Drawn from benchd's document under `HELM_BENCH=daemon` (#354), from helm's own state
    /// otherwise.
    @StateObject private var workbench = WorkbenchModel(
        terminals: .shared, mode: .fromEnvironment())
    @StateObject private var archonRail = ArchonRailModel()
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
            StatusBarView(model: model, workbench: workbench)
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
            if workbench.mode.client != nil {
                // benchd holds the workspaces and their benches; helm follows the document and
                // saves none of it.
                workbench.followDocuments(BenchImport.follower(model: model, workbench: workbench))
            } else {
                model.observe(terminals: terminalManager, workbench: workbench)
                workbench.workspaceVerbs = apply
            }
            let actions = LocalActions(
                workbench: workbench, workspaces: model, rail: archonRail,
                terminals: terminalManager)
            self.actions = actions
            Actions.performer = actions
            // A push from a parked workspace lands on its stored bench, which this model holds
            // (#349). Drawn from benchd, a parked bench is benchd's, and the document says
            // which workspace is on screen.
            if workbench.mode.client == nil {
                workbench.parked = model
                activateSelectedWorkspace()
            }
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
            // The spool (#54) — the one seam an agent with no display can drive. It is wired
            // here for the same reason `observe` is: opening a workspace spans the workspace
            // list and the bench together, and `openWorkspace` is where that already lives.
            spool.attach(
                spawner: WorkbenchSpoolSpawner(
                    workbench: workbench, terminals: terminalManager,
                    // The non-asking open, and it is load-bearing rather than tidy — see
                    // `openWorkspaceForRequest`.
                    activate: openWorkspaceForRequest))
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

    /// The workspace verbs, which `LocalSink` hands here because they span the workspace list
    /// and the bench together.
    private func apply(_ verb: WorkspaceVerb) {
        switch verb {
        case let .open(path):
            openWorkspace(Workspace(path: path))
        case let .activate(path):
            if let workspace = workspace(at: path) { switchWorkspace(workspace) }
        case let .close(path):
            if let workspace = workspace(at: path) { closeWorkspace(workspace) }
        }
    }

    private func workspace(at path: String) -> Workspace? {
        model.workspaces.first { $0.path == WorkspacePath(path) }
    }

    private func persistCurrentContext() {
        model.saveContext(terminalManager: terminalManager, workbench: workbench)
    }

    private func openWorkspace(_ workspace: Workspace) {
        persistCurrentContext()
        model.open(workspace)
        activateSelectedWorkspace()
    }

    /// The same open, reached from a **spool spawn** whose `cwd` becomes a workspace (#54).
    ///
    /// It differs in one line — the mount it takes — and the difference is spelled here rather
    /// than behind a flag, which is `Workbench.splitRight(_:movingFocus:)`'s shape. A spawn
    /// must never raise #85's restore question: the spool exists for the case where nobody is
    /// at the pane, so a question raised from one is #179's silent hang with a different cause.
    private func openWorkspaceForRequest(_ workspace: Workspace) {
        // Drawn from benchd, a spawn's workspace is an agent's `workspace/open`: it opens in the
        // background, and the spawned terminal lands there (`WorkbenchSpoolSpawner`).
        if workbench.mode.client != nil {
            workbench.send(.workspaceOpen(path: workspace.path.value), by: .agent())
            return
        }
        persistCurrentContext()
        model.open(workspace)
        activateSelectedWorkspace(asking: false)
    }

    private func closeWorkspace(_ workspace: Workspace) {
        persistCurrentContext()
        let wasSelected = model.selectedWorkspace == workspace
        // Both teardowns are unconditional, and both have to be: the branches below run
        // only when the workspace being closed was the selected one, and a background
        // workspace can be closed from any tab's context menu.
        terminalManager.closeWorkspace(workspace.path)
        workbench.closeWorkspace(workspace.path)
        model.close(workspace)
        if wasSelected, let replacement = model.workspaces.first {
            model.select(replacement)
            activateSelectedWorkspace()
        } else if wasSelected {
            terminalManager.deactivate()
            workbench.deactivate()
        }
    }

    private func switchWorkspace(_ workspace: Workspace) {
        guard model.selectedWorkspace != workspace else { return }
        persistCurrentContext()
        model.select(workspace)
        activateSelectedWorkspace()
    }

    /// The persisted bench, else the one a pre-bench context describes, else nothing —
    /// which `WorkbenchModel.activate` turns into today's 1×1 frame.
    ///
    /// **Whether any of it is opened is the bench's decision, not this view's** (#85).
    /// `BenchMountPolicy` is where "restore or ask" is decided and it is pure; this hands over
    /// both candidates and nothing else. Three defects in two days came from logic living in a
    /// view, which is why the ticket names that as an acceptance criterion.
    private func activateSelectedWorkspace(asking: Bool = true) {
        guard let workspace = model.selectedWorkspace else { return }
        let context = model.contexts[workspace.path.value] ?? WorkspaceContext()
        let saved = context.workbench ?? .migrating(from: context)
        if asking {
            workbench.activate(
                workspacePath: workspace.path, offering: saved, shelved: context.shelvedBench)
        } else {
            workbench.activate(
                workspacePath: workspace.path, restoring: saved, shelved: context.shelvedBench)
        }
    }
}
