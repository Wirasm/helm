import Foundation

/// The open folders and their per-workspace UI state.
///
/// This is the workspace half of what used to live in `KildStore`, extracted when the kild
/// layer was removed. Nothing here talks to a backend: a workspace is a folder the operator
/// opened, its identity is the normalised path, and everything persisted is a local
/// preference. There was never a registration, so there is nothing to unregister.
@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var workspaces: [Workspace]
    @Published private(set) var selectedWorkspace: Workspace?
    @Published private(set) var contexts: [String: WorkspaceContext]

    /// The selected workspace's path, for anything that needs a root without needing the
    /// workspace itself.
    var selectedWorkspaceRoot: String? { selectedWorkspace?.path }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workspaces = WorkspacePersistence.load(from: defaults)
        contexts = WorkspaceContextStore.load(from: defaults)
        selectedWorkspace = WorkspacePersistence.loadSelection(
            from: defaults, in: WorkspacePersistence.load(from: defaults))
    }

    /// Open a folder and select it. Opening one already open just selects it — the
    /// normalised path is the identity, so this cannot duplicate.
    func open(_ workspace: Workspace) {
        if !workspaces.contains(workspace) {
            workspaces.append(workspace)
            WorkspacePersistence.save(workspaces, to: defaults)
        }
        select(workspace)
    }

    /// Drop a workspace from the list. Purely local.
    func close(_ workspace: Workspace) {
        workspaces.removeAll { $0 == workspace }
        WorkspacePersistence.save(workspaces, to: defaults)
        contexts[workspace.path] = nil
        WorkspaceContextStore.save(contexts, to: defaults)
        if selectedWorkspace == workspace { select(nil) }
    }

    func select(_ workspace: Workspace?) {
        selectedWorkspace = workspace
        WorkspacePersistence.saveSelection(workspace, to: defaults)
    }

    /// Save the current workspace's UI state before switching away from it.
    ///
    /// `TerminalManager` retains the sessions themselves; only their ids and which one was
    /// selected are context state. The artifact is stored as a path rather than a document
    /// so a workspace can be restored without the file having to still be readable.
    func saveContext(terminalManager: TerminalManager, artifact: ArtifactPaneModel) {
        guard let workspace = selectedWorkspace else { return }
        var context = contexts[workspace.path] ?? WorkspaceContext()
        context.terminalSessionIDs = terminalManager.sessions(for: workspace.path).map(\.id)
        context.selectedTerminalID =
            terminalManager.selected?.workspacePath == workspace.path
            ? terminalManager.selectedID : nil
        context.openArtifactPath = artifact.document?.url.path
        contexts[workspace.path] = context
        WorkspaceContextStore.save(contexts, to: defaults)
    }

    /// Remember a workspace's git branch for its tab label.
    ///
    /// `branchResolved` is set whether or not a branch was found, so a folder that is not a
    /// repository is asked once rather than on every render. Absence is a resolved answer.
    func cacheBranch(_ branch: String?, for workspace: Workspace) {
        var context = contexts[workspace.path] ?? WorkspaceContext()
        context.branch = branch
        context.branchResolved = true
        contexts[workspace.path] = context
        WorkspaceContextStore.save(contexts, to: defaults)
    }
}
