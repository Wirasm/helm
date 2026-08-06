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
    /// Keyed by `WorkspacePath.value`, not `WorkspacePath` itself: `Dictionary` only encodes
    /// as a JSON object when its key is `String` (or `Int`), so a `WorkspacePath` key would
    /// change `helmWorkspaceContexts`'s shape and strand a context saved before this type
    /// existed.
    @Published private(set) var contexts: [String: WorkspaceContext]

    /// The selected workspace's path, for anything that needs a root without needing the
    /// workspace itself.
    var selectedWorkspaceRoot: WorkspacePath? { selectedWorkspace?.path }

    private let defaults: UserDefaults
    private var terminalChanges: AnyCancellable?
    private var workbenchChanges: AnyCancellable?

    init(defaults: UserDefaults = DefaultsDomain.store) {
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
        contexts[workspace.path.value] = nil
        WorkspaceContextStore.save(contexts, to: defaults)
        if selectedWorkspace == workspace { select(nil) }
    }

    func select(_ workspace: Workspace?) {
        selectedWorkspace = workspace
        WorkspacePersistence.saveSelection(workspace, to: defaults)
    }

    /// Save the current workspace's UI state before switching away from it.
    ///
    /// One field now carries what three used to: the bench holds the terminal ids, which
    /// pane each slot has selected, and **which canvas held which file or URL**. The three
    /// legacy fields are still read on load (they are the migration source) but are no
    /// longer written — a URL canvas persists properly now, rather than persisting nothing
    /// because `openArtifactPath` could only hold a file path.
    func saveContext(terminalManager: TerminalManager, workbench: WorkbenchModel) {
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
        // The bench's twin of the guard above, and it exists for the same failure: a save
        // that runs before `.task` activates the workspace would write an EMPTY bench over
        // the one restore is about to read.
        guard workbench.workspacePath == workspace.path, let bench = workbench.bench else {
            return
        }
        var context = contexts[workspace.path.value] ?? WorkspaceContext()
        context.workbench = bench
        contexts[workspace.path.value] = context
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
    ///
    /// Both publishers are sunk, so opening a terminal, switching a tab, splitting a
    /// column and dragging a divider all persist. Two saves per change where both fire is
    /// harmless — the write is a small JSON blob to `UserDefaults`, and nothing here is
    /// per-keystroke: `CanvasModel` holds only committed addresses, never a half-typed one.
    func observe(terminals manager: TerminalManager, workbench: WorkbenchModel) {
        let save: @MainActor () -> Void = { [weak self] in
            self?.saveContext(terminalManager: manager, workbench: workbench)
        }
        terminalChanges = manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { MainActor.assumeIsolated(save) }
        workbenchChanges = workbench.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { MainActor.assumeIsolated(save) }
    }

    /// Remember a workspace's git branch for its tab label.
    ///
    /// `branchResolved` is set whether or not a branch was found, so a folder that is not a
    /// repository is asked once rather than on every render. Absence is a resolved answer.
    func cacheBranch(_ branch: String?, for workspace: Workspace) {
        var context = contexts[workspace.path.value] ?? WorkspaceContext()
        context.branch = branch
        context.branchResolved = true
        contexts[workspace.path.value] = context
        WorkspaceContextStore.save(contexts, to: defaults)
    }
}
