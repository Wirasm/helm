import Inject
import SwiftUI

/// helm's permanent frame: the workspace bar above the workbench.
///
/// **Composition only**, and more so than before. The canvas is no longer a special case
/// wired in here — it is a bench pane, so the dock's `HSplitView` and the single
/// `CanvasModel` are both gone. Every subscription left below touches two or more
/// verticals at once: persisting a workspace's context needs the workspace and its bench
/// together, and switching workspaces has to move both. Anything that can name a single
/// vertical belongs in that vertical's slice — the terminal and canvas commands live on
/// `WorkbenchModel`, whose lifetime is right for them.
struct RootView: View {
    @ObserveInjection private var inject
    @StateObject private var model = WorkspaceModel()
    /// A `@StateObject` rather than a `.shared`: `TerminalManager.shared` and
    /// `BoardModel.shared` are singletons because other slices reach them, and nothing
    /// outside the workbench reaches this one.
    @StateObject private var workbench = WorkbenchModel(terminals: .shared)
    @ObservedObject private var terminalManager = TerminalManager.shared

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceBar(
                model: model, select: switchWorkspace, open: openWorkspace,
                close: closeWorkspace)
            WorkbenchView(model: workbench, workspaceRoot: model.selectedWorkspaceRoot)
        }
        .task {
            model.observe(terminals: terminalManager, workbench: workbench)
            activateSelectedWorkspace()
            // The screenshot harness's `--artifact <path>`. `tools/winshot.swift` uses it;
            // it opens into whichever pane placement chooses, exactly like a ⌘-clicked link.
            if let path = LaunchOptions.artifactPath {
                workbench.open(
                    .file(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
            }
        }
        // The context is written by `WorkspaceModel.observe`, which sinks BOTH the
        // manager's and the bench's `objectWillChange`. It lives on the model rather than
        // here for the reason that file records at length: two earlier attempts in this
        // view lost writes, one by rebuilding its publisher on every body evaluation and
        // one by trapping the app outright.
        .onReceive(NotificationCenter.default.publisher(for: .helmSelectWorkspace)) { note in
            guard let index = note.object as? Int, model.workspaces.indices.contains(index) else {
                return
            }
            switchWorkspace(model.workspaces[index])
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmCycleWorkspace)) { note in
            guard let direction = note.object as? Int, !model.workspaces.isEmpty else { return }
            let current =
                model.selectedWorkspace.flatMap { model.workspaces.firstIndex(of: $0) } ?? 0
            let next = (current + direction + model.workspaces.count) % model.workspaces.count
            switchWorkspace(model.workspaces[next])
        }
        .enableInjection()
    }

    private func persistCurrentContext() {
        model.saveContext(terminalManager: terminalManager, workbench: workbench)
    }

    private func openWorkspace(_ workspace: Workspace) {
        persistCurrentContext()
        model.open(workspace)
        activateSelectedWorkspace()
    }

    private func closeWorkspace(_ workspace: Workspace) {
        persistCurrentContext()
        let wasSelected = model.selectedWorkspace == workspace
        terminalManager.closeWorkspace(workspace.path)
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
    private func activateSelectedWorkspace() {
        guard let workspace = model.selectedWorkspace else { return }
        let context = model.contexts[workspace.path] ?? WorkspaceContext()
        workbench.activate(
            workspacePath: workspace.path,
            restoring: context.workbench ?? .migrating(from: context))
    }
}
