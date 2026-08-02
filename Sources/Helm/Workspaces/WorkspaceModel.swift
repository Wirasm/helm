import Combine
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
    private var terminalChanges: AnyCancellable?

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
    ///
    /// A canvas showing a **URL** persists nothing — `fileURL` is nil for it, so the field
    /// keeps meaning what its name says. Restoring one is not on the map yet, and half-doing
    /// it here would put a `https:` string where a file path is read back.
    func saveContext(terminalManager: TerminalManager, artifact: CanvasModel) {
        guard let workspace = selectedWorkspace else { return }
        // Never record a workspace that is not mounted. Until `TerminalManager.activate`
        // has run for it there are no sessions to see, so saving would write an EMPTY tab
        // row over the one a relaunch is about to restore from.
        //
        // That is not hypothetical — it is what made restore look broken. A `@Published`
        // projection republishes its current value the moment something subscribes, so
        // `onReceive(artifact.$source)` fired during the first body evaluation, which is
        // *before* `.task` activates the workspace. The saved row was wiped and then read
        // back empty, so a relaunch restored one fresh shell no matter what had been open.
        //
        // Guarding here rather than at each call site is deliberate: the wipe came from a
        // subscription nobody thought of as a save, and the next one will too.
        guard terminalManager.activeWorkspacePath == workspace.path else { return }
        var context = contexts[workspace.path] ?? WorkspaceContext()
        context.terminalSessionIDs = terminalManager.sessions(for: workspace.path).map(\.id)
        context.selectedTerminalID =
            terminalManager.selected?.workspacePath == workspace.path
            ? terminalManager.selectedID : nil
        context.openArtifactPath = artifact.fileURL?.path
        contexts[workspace.path] = context
        WorkspaceContextStore.save(contexts, to: defaults)
    }

    /// Persist this workspace's context whenever its terminals change.
    ///
    /// On the model rather than in a `View`, for the reason `AGENTS.md` gives: a
    /// subscription's lifetime should be its owner's, not a render's. Two earlier
    /// attempts sat in `RootView` —
    ///
    /// - `.onReceive(manager.$sessions.dropFirst())` builds a **new publisher every body
    ///   evaluation**, so `onReceive` resubscribes and `dropFirst` eats the next real
    ///   event each time. Reasoned, not measured: the live evidence originally cited for
    ///   it turned out to be the separate wipe that `saveContext` now guards against.
    /// - `for await _ in manager.objectWillChange.values` **traps**, and this one is
    ///   measured — `ObservableObjectPublisher` does not honour `AsyncPublisher`'s demand,
    ///   so two changes in quick succession killed the app with "Received an output
    ///   without requesting demand".
    ///
    /// A stored `sink` has unlimited demand, so it cannot trap, and one instance lives
    /// as long as the model. `receive(on:)` is load-bearing rather than decoration:
    /// `@Published` fires in `willSet`, so reading the manager synchronously would see
    /// the value from *before* the change. The main-queue hop lands after it.
    /// `self` is weak because the closure is stored on `self`; the collaborators are held
    /// **strongly**, and that is deliberate. Neither references this model back, so there
    /// is no cycle — and capturing them weakly gives the subscription a way to go quietly
    /// dead if anything but a view ever owns them, which is the failure mode this whole
    /// area kept producing. A regression test caught exactly that.
    func observeTerminals(_ manager: TerminalManager, artifact: CanvasModel) {
        terminalChanges = manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.saveContext(terminalManager: manager, artifact: artifact)
                }
            }
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
