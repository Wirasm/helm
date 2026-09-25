import Combine
import Foundation

/// The open folders and their per-workspace UI state.
///
/// This is the workspace half of what used to live in `KildStore`, extracted when the kild
/// layer was removed. Nothing here talks to a backend: a workspace is a folder the operator
/// opened, its identity is the normalised path, and everything persisted is a local
/// preference. There was never a registration, so there is nothing to unregister.
@MainActor
final class WorkspaceModel: ObservableObject, ParkedBenches {
    @Published private(set) var workspaces: [Workspace]
    @Published private(set) var selectedWorkspace: Workspace?
    /// Keyed by `WorkspacePath.value`, not `WorkspacePath` itself: `Dictionary` only encodes
    /// as a JSON object when its key is `String` (or `Int`), so a `WorkspacePath` key would
    /// change `helmWorkspaceContexts`'s shape and strand a context saved before this type
    /// existed.
    @Published private(set) var contexts: [String: WorkspaceContext]
    /// Each workspace's current git branch, for its tab label. Never persisted: see
    /// `refreshBranch(for:)`.
    @Published private(set) var branches: [WorkspacePath: String] = [:]

    /// The selected workspace's path, for anything that needs a root without needing the
    /// workspace itself.
    var selectedWorkspaceRoot: WorkspacePath? { selectedWorkspace?.path }

    private let defaults: UserDefaults
    private let readBranch: @Sendable (WorkspacePath) async -> String?
    private var terminalChanges: AnyCancellable?
    private var workbenchChanges: AnyCancellable?

    init(
        defaults: UserDefaults = DefaultsDomain.store,
        readBranch: @escaping @Sendable (WorkspacePath) async -> String? = currentBranch(in:)
    ) {
        self.defaults = defaults
        self.readBranch = readBranch
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
        branches[workspace.path] = nil
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
        // The shelf rides along with the save that would otherwise have overwritten what is on
        // it (#85). Written from the model rather than by a call of its own, because the two
        // values have to land in the same write: a fresh bench persisted without its shelf, or
        // a shelf persisted without the bench that replaced it, is exactly the half-state the
        // field exists to prevent.
        context.shelvedBench = workbench.shelvedBench
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

    /// Put a canvas on a parked workspace's stored bench (#349) — what switching back to it will
    /// mount (`RootView.activateSelectedWorkspace`).
    ///
    /// Written and saved only on a real change: a re-push of a canvas already there changes
    /// nothing here, and every save reaches `UserDefaults`.
    func offer(_ source: CanvasSource, toBenchOf path: WorkspacePath) -> Pane.ID? {
        guard var context = contexts[path.value], var bench = context.workbench else {
            return nil
        }
        let pane = bench.offer(canvas: source)
        if bench != context.workbench {
            context.workbench = bench
            contexts[path.value] = context
            WorkspaceContextStore.save(contexts, to: defaults)
        }
        return pane
    }

    /// Ask git which branch a workspace is on now, for its tab label.
    ///
    /// Asked every time, never remembered: before #379 the answer was persisted with a
    /// `branchResolved` flag that stopped every later ask, so a tab showed the branch its folder
    /// had the first time it was opened, across relaunches, forever. A nil answer clears the label,
    /// because a folder that stopped being a repository, or a detached HEAD, has no branch to show.
    ///
    /// The answer is dropped when it arrives too late to be true: the tab's task was cancelled
    /// because the selection moved on and a newer ask is running, or the workspace was closed
    /// while git was running and would otherwise get a label back.
    func refreshBranch(for workspace: Workspace) async {
        let branch = await readBranch(workspace.path)
        guard !Task.isCancelled, workspaces.contains(workspace) else { return }
        branches[workspace.path] = branch
    }
}

extension WorkspaceModel {
    /// `git branch --show-current`, through `Subprocess`, so the wait holds no thread. Nil when
    /// git fails, times out or prints nothing: not a repository, or a detached HEAD. A cancelled
    /// ask is nil too, and `refreshBranch` drops it.
    nonisolated static func currentBranch(in path: WorkspacePath) async -> String? {
        guard
            let result = try? await Subprocess.run(
                ["git", "-C", path.value, "branch", "--show-current"],
                environment: ProcessInfo.processInfo.environment,
                timeout: .seconds(10)),
            result.status == 0
        else { return nil }
        let value = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
