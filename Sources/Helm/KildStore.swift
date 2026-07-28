import Foundation

/// App-level state for the whole frame: which folder you have open, and what the engine
/// says about it.
///
/// **Two halves, deliberately composed rather than merged.** `Cockpit` owns everything the
/// engine reports and nothing else; this type owns the workspace — a folder helm simply has
/// open, which the engine has never heard of. The old store conflated them, and the seam is
/// worth keeping visible: workspace state is persisted locally and survives an engine
/// restart, engine state is discarded on one.
///
/// One instance lives at RootView scope, fed by ONE poller. Never a poller per column.
@MainActor
final class KildStore: ObservableObject {
    /// Everything the engine reports. Read it directly for kilds, attention and collisions.
    let cockpit: Cockpit

    /// Where the open-workspace list is persisted — injectable so tests never touch
    /// the operator's real defaults.
    private let defaults: UserDefaults

    /// The selected kild id — the sidebar drives it, the dock renders it (a selected kild
    /// wins the dock over any open artifact).
    @Published var selection: String? = LaunchOptions.kildId
    @Published var tab: KildsTab = .live
    /// Local archive search. The archive listing is already in hand, so filtering names and
    /// agents is immediate and needs no extra poll.
    ///
    /// It can no longer search message text: the archive carries **no log** — that was the
    /// most expensive listing in the engine and it was removed. Searching prose again would
    /// mean fetching every archived kild's messages, which is exactly the cost the removal
    /// bought back.
    @Published var historyQuery = ""
    /// Agent disclosure state, per workspace, persisted in its context.
    @Published var expandedKilds: Set<String> = []
    @Published private(set) var contexts: [String: WorkspaceContext]

    /// The kild named on the command line, if any.
    ///
    /// Held separately from `selection` because restoring a workspace context **overwrites**
    /// the selection — `applyContext` assigns it unconditionally. Reading the flag back out
    /// of `selection` therefore fails exactly when a context exists, which is the normal
    /// case, and fails silently: the harness captures whatever kild was selected last
    /// instead of the one it named, and nothing reports a problem.
    private let launchKild: String? = LaunchOptions.kildId

    /// A `--kild` launch lands on History when the id is not live at first load; the first
    /// load corrects the tab once data arrives (testability seam).
    private var launchKildResolved = LaunchOptions.kildId == nil

    @Published private(set) var workspaces: [Workspace]
    @Published private(set) var selectedWorkspace: Workspace?
    /// The selected workspace's repo root — the main checkout even when the workspace is a
    /// worktree of it. Resolved off the main thread on selection (it shells out to git) and
    /// consumed by the artifact browser to preselect the matching `~/.prp` store.
    @Published private(set) var selectedWorkspaceRoot: String?

    init(api: KildAPI = KildHTTPClient(), defaults: UserDefaults = .standard) {
        self.cockpit = Cockpit(api: api)
        self.defaults = defaults
        let restoredWorkspaces = WorkspacePersistence.load(from: defaults)
        let restoredContexts = WorkspaceContextStore.load(from: defaults)
        workspaces = restoredWorkspaces
        selectedWorkspace = WorkspacePersistence.loadSelection(
            from: defaults, in: restoredWorkspaces)
        contexts = restoredContexts
        if let selectedWorkspace {
            applyContext(for: selectedWorkspace)
        }
        // An explicit `--kild` outranks whatever the restored context had selected.
        // Applied AFTER applyContext, which assigns `selection` unconditionally.
        if let launchKild { selection = launchKild }
    }

    // MARK: - What the sidebar shows

    /// Live kilds under the workspace filter, grouped and sorted.
    ///
    /// Attribution is `Kild.cwd` rather than a worktree-name lookup: `/api/worktrees` was
    /// deleted with no successor, and `cwd` is the project directory, persisted, present
    /// even on an orphan. One less request and one less way to be wrong.
    var shownGroups: [KildGroup: [Kild]] {
        let scoped = selectedWorkspace.map {
            WorkspaceAttribution.kilds(in: $0.path, from: cockpit.kilds)
        } ?? cockpit.kilds
        return Attention.grouped(scoped)
    }

    /// Archived kilds under the workspace filter, newest first, matching the search.
    var shownArchive: [ArchivedKild] {
        let scoped = selectedWorkspace.map {
            WorkspaceAttribution.archived(in: $0.path, from: cockpit.archive)
        } ?? cockpit.archive
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scoped }
        return scoped.filter { $0.matchesSearch(query) }
    }

    /// The dock's tenant: the selection resolved against what is actually shown, so a kild
    /// hidden by the workspace filter yields the dock back to the artifact.
    var selectedKild: Kild? {
        shownGroups.values.flatMap { $0 }.first { $0.id == selection }
    }

    /// Collisions for the selected kild. Derived — label it as such wherever it renders.
    var selectedCollisions: [Collision] {
        selection.flatMap { cockpit.collisions[$0] } ?? []
    }

    /// How many agents are waiting on you, across every kild in the open workspace.
    var waitingCount: Int {
        let scoped = selectedWorkspace.map {
            WorkspaceAttribution.kilds(in: $0.path, from: cockpit.kilds)
        } ?? cockpit.kilds
        return Attention.waitingCount(in: scoped)
    }

    // MARK: - Workspaces

    /// Open a folder as a workspace and select it. Opening one already open just
    /// selects it — the normalised path is the identity, so this cannot duplicate.
    func open(_ workspace: Workspace) {
        if !workspaces.contains(workspace) {
            workspaces.append(workspace)
            WorkspacePersistence.save(workspaces, to: defaults)
        }
        select(workspace)
    }

    /// Drop a workspace from the list. Purely local — there was never a
    /// registration, so there is nothing to unregister engine-side.
    func close(_ workspace: Workspace) {
        workspaces.removeAll { $0 == workspace }
        WorkspacePersistence.save(workspaces, to: defaults)
        contexts[workspace.path] = nil
        WorkspaceContextStore.save(contexts, to: defaults)
        if selectedWorkspace == workspace { select(nil) }
    }

    /// Saves the current workspace's UI state before changing the filter.
    /// TerminalManager retains the resources themselves; only their IDs and
    /// selection are context state.
    func saveContext(terminalManager: TerminalManager, artifact: ArtifactPaneModel) {
        guard let workspace = selectedWorkspace else { return }
        var context = contexts[workspace.path] ?? WorkspaceContext()
        let workspaceSessions = terminalManager.sessions(for: workspace.path)
        context.terminalSessionIDs = workspaceSessions.map(\.id)
        context.selectedTerminalID =
            terminalManager.selected?.workspacePath == workspace.path
            ? terminalManager.selectedID : nil
        context.selectedKildID = selection
        context.kildsTab = tab
        context.historyQuery = historyQuery
        context.expandedKilds = expandedKilds
        context.openArtifactPath = artifact.document?.url.path
        contexts[workspace.path] = context
        WorkspaceContextStore.save(contexts, to: defaults)
    }

    func applyContext(for workspace: Workspace) {
        let context = contexts[workspace.path] ?? WorkspaceContext()
        selection = context.selectedKildID
        tab = context.kildsTab
        historyQuery = context.historyQuery
        expandedKilds = context.expandedKilds
    }

    func composerDraft(for kildID: String) -> String {
        guard let workspace = selectedWorkspace else { return "" }
        return contexts[workspace.path]?.composerDrafts[kildID] ?? ""
    }

    func setComposerDraft(_ draft: String, for kildID: String) {
        guard let workspace = selectedWorkspace else { return }
        var context = contexts[workspace.path] ?? WorkspaceContext()
        context.composerDrafts[kildID] = draft.isEmpty ? nil : draft
        contexts[workspace.path] = context
        WorkspaceContextStore.save(contexts, to: defaults)
    }

    func cacheBranch(_ branch: String?, for workspace: Workspace) {
        var context = contexts[workspace.path] ?? WorkspaceContext()
        context.branch = branch
        context.branchResolved = true
        contexts[workspace.path] = context
        WorkspaceContextStore.save(contexts, to: defaults)
    }

    func select(_ workspace: Workspace?) {
        selectedWorkspace = workspace
        selectedWorkspaceRoot = nil
        WorkspacePersistence.saveSelection(workspace, to: defaults)
        guard let workspace else { return }
        applyContext(for: workspace)
        Task { await refreshWorkspaceRoot() }
    }

    /// The repo root the selected workspace's `~/.prp` store is keyed by.
    ///
    /// Shorter than it was: resolving a workspace's kild worktrees needed a second request
    /// to `/api/worktrees`, which is gone. `Kild.cwd` answers it directly now, so only the
    /// git root resolution remains — and that runs once per selection, never per render.
    private func refreshWorkspaceRoot() async {
        guard let selectedWorkspace, selectedWorkspaceRoot == nil else { return }
        let path = selectedWorkspace.path
        let root = await Task.detached { WorkspaceStore.repositoryRoot(for: path) }.value
        guard self.selectedWorkspace == selectedWorkspace else { return }
        selectedWorkspaceRoot = root
    }

    // MARK: - Polling

    /// The cheap tick: identity, agents, attention. Safe to run often.
    func loadIdentities() async {
        await cockpit.checkBoot()
        await cockpit.refreshIdentities()
        resolveLaunchSelection()
    }

    /// The costly tick: git and cost, one subprocess per kild. Belongs on a slower cadence.
    func loadStatus() async {
        await cockpit.refreshStatus()
    }

    func loadArchive() async {
        await cockpit.refreshArchive()
        resolveLaunchSelection()
    }

    /// A `--kild` launch that names an archived kild should land on History rather than
    /// showing an empty Live tab. Runs once, after data has actually arrived.
    private func resolveLaunchSelection() {
        // Reads the FLAG, not `selection` — a restored context may have replaced the
        // selection since launch, and flipping to History for a kild the operator never
        // named is worse than not flipping at all.
        guard !launchKildResolved, let id = launchKild else { return }
        guard !cockpit.kilds.isEmpty || !cockpit.archive.isEmpty else { return }
        if cockpit.archive.contains(where: { $0.id == id }) { tab = .history }
        launchKildResolved = true
    }
}

extension ArchivedKild {
    /// Archive search over what the listing actually carries.
    ///
    /// Names and agent handles only. The archive no longer ships its log — that was the
    /// engine's most expensive listing, and removing it is what made "list my stopped
    /// kilds" stop meaning "send me every conversation I have ever had". Searching prose
    /// would mean fetching every archived kild's messages, which spends exactly what the
    /// removal saved.
    func matchesSearch(_ query: String) -> Bool {
        var fields = [id, name]
        if let worktree { fields.append(worktree) }
        fields.append(contentsOf: agents.flatMap { [$0.handle, $0.persona, $0.model].compactMap { $0 } })
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
