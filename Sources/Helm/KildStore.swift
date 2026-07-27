import Foundation

/// App-level kild engine state — the observe/steer data the whole frame shares.
/// One instance lives at RootView scope, fed by ONE 5s poller (RootView owns the
/// tick; never a poller per column): the sidebar column renders this store, the
/// right dock hosts the selected room's detail. Polling for now; a later slice
/// owns WS. Attention-first, per the seed plan: open decisions outrank everything.
@MainActor
final class KildStore: ObservableObject {
    enum RoomsTab: String, Codable, Equatable {
        case live
        case history
    }

    let engine: EngineClient
    /// Where the open-workspace list is persisted — injectable so tests never touch
    /// the operator's real defaults.
    private let defaults: UserDefaults

    @Published var health: EngineClient.Health?
    @Published var rooms: [EngineClient.LiveRoom] = []
    @Published var archived: [EngineClient.ArchivedRoom] = []
    @Published var error: String?

    /// The selected room id — the sidebar's list drives it, the dock renders it
    /// (a selected room wins the dock over any open artifact).
    @Published var selection: String? = LaunchOptions.roomId
    @Published var tab: RoomsTab = .live
    /// Local archive search. The engine already delivered the archive, so filtering
    /// names, participants, decisions and posts is immediate and needs no extra poll.
    @Published var historyQuery = ""
    @Published private(set) var contexts: [String: WorkspaceContext]
    // A --room launch lands on History when the id isn't live at first load; the
    // load() pass below corrects the tab once data arrives (testability seam).
    private var launchRoomResolved = LaunchOptions.roomId == nil

    // The workspace filter. `selectedWorkspace == nil` = all rooms.
    // `workspaceWorktreeNames` is the selected folder's kild worktrees (from
    // `/api/worktrees`) — the only link from a worktree-room back to its workspace,
    // since worktree dirs live under `$KILD_HOME`, not under the folder.
    @Published private(set) var workspaces: [Workspace]
    @Published private(set) var selectedWorkspace: Workspace?
    @Published private(set) var workspaceWorktreeNames: Set<String> = []
    /// The selected workspace's repo root — the main checkout even when the
    /// workspace is a worktree of it. Resolved off the main thread on selection
    /// (it shells out to git) and consumed by the artifact browser to preselect
    /// the matching `~/.prp` store.
    @Published private(set) var selectedWorkspaceRoot: String?

    init(engine: EngineClient = EngineClient(), defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        let restoredWorkspaces = WorkspacePersistence.load(from: defaults)
        let restoredContexts = WorkspaceContextStore.load(from: defaults)
        workspaces = restoredWorkspaces
        selectedWorkspace = WorkspacePersistence.loadSelection(from: defaults, in: restoredWorkspaces)
        contexts = restoredContexts
        if let selectedWorkspace {
            applyContext(for: selectedWorkspace)
        }
    }

    /// The current tab's rooms under the workspace filter. Live rooms sort
    /// attention-first (open decisions on top); the archive sorts newest-activity first.
    var shownRooms: [EngineClient.LiveRoom] {
        let source = tab == .live ? rooms : archived
        let workspaceFiltered = selectedWorkspace.map { workspace in
            source.filter {
                $0.belongsToProject(at: workspace.path, worktreeNames: workspaceWorktreeNames)
            }
        } ?? source
        if tab == .live {
            return workspaceFiltered.sorted {
                ($0.openDecisions.isEmpty ? 1 : 0, $0.name) < ($1.openDecisions.isEmpty ? 1 : 0, $1.name)
            }
        }
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = query.isEmpty
            ? workspaceFiltered
            : workspaceFiltered.filter { $0.matchesArchiveSearch(query) }
        return searched.sorted { ($0.log.last?.ts ?? 0) > ($1.log.last?.ts ?? 0) }
    }

    /// The dock's room tenant: the selection resolved against the SHOWN list, so
    /// a room hidden by the workspace filter yields the dock back to the artifact.
    var selectedRoom: EngineClient.LiveRoom? {
        shownRooms.first { $0.id == selection }
    }

    // MARK: workspaces

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

    /// Saves the current workspace's UI state before changing the room filter.
    /// TerminalManager retains the resources themselves; only their IDs and
    /// selection are context state.
    func saveContext(terminalManager: TerminalManager, artifact: ArtifactPaneModel) {
        guard let workspace = selectedWorkspace else { return }
        var context = contexts[workspace.path] ?? WorkspaceContext()
        let workspaceSessions = terminalManager.sessions(for: workspace.path)
        context.terminalSessionIDs = workspaceSessions.map(\.id)
        context.selectedTerminalID = terminalManager.selected?.workspacePath == workspace.path
            ? terminalManager.selectedID : nil
        context.selectedRoomID = selection
        context.roomsTab = tab
        context.historyQuery = historyQuery
        context.openArtifactPath = artifact.document?.url.path
        contexts[workspace.path] = context
        WorkspaceContextStore.save(contexts, to: defaults)
    }

    func applyContext(for workspace: Workspace) {
        let context = contexts[workspace.path] ?? WorkspaceContext()
        selection = context.selectedRoomID
        tab = context.roomsTab
        historyQuery = context.historyQuery
    }

    func composerDraft(for roomID: String) -> String {
        guard let workspace = selectedWorkspace else { return "" }
        return contexts[workspace.path]?.composerDrafts[roomID] ?? ""
    }

    func setComposerDraft(_ draft: String, for roomID: String) {
        guard let workspace = selectedWorkspace else { return }
        var context = contexts[workspace.path] ?? WorkspaceContext()
        if draft.isEmpty { context.composerDrafts[roomID] = nil } else { context.composerDrafts[roomID] = draft }
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
        workspaceWorktreeNames = []
        selectedWorkspaceRoot = nil
        WorkspacePersistence.saveSelection(workspace, to: defaults)
        guard let workspace else { return }
        applyContext(for: workspace)
        Task { await refreshWorkspaceContext() }
    }

    /// What the selected workspace implies: its kild worktree names, and the repo
    /// root its `~/.prp` store is keyed by. Also runs on every poll, which is what
    /// resolves a selection restored from defaults at launch.
    private func refreshWorkspaceContext() async {
        guard let selectedWorkspace else { return }
        // Best-effort: a folder that isn't a git repo legitimately 400s, and that
        // only disables worktree matching.
        let trees = (try? await engine.worktrees(path: selectedWorkspace.path)) ?? []
        guard self.selectedWorkspace == selectedWorkspace else { return }
        workspaceWorktreeNames = Set(trees.compactMap(\.worktree))
        guard selectedWorkspaceRoot == nil else { return }
        // git subprocess — off the main thread, once per selection, never per
        // render (the browser then matches stores against the root purely).
        let path = selectedWorkspace.path
        let root = await Task.detached { WorkspaceStore.repositoryRoot(for: path) }.value
        guard self.selectedWorkspace == selectedWorkspace else { return }
        selectedWorkspaceRoot = root
    }

    func load() async {
        do {
            health = try await engine.health()
            rooms = try await engine.liveRooms()
            archived = try await engine.archivedRooms()
            await refreshWorkspaceContext()
            error = nil
            if !launchRoomResolved, let id = selection {
                if archived.contains(where: { $0.id == id }) { tab = .history }
                launchRoomResolved = true
            }
        } catch {
            health = nil
            rooms = []
            archived = []
            self.error = "Start it: cd sild/kild/engine && bun run serve"
        }
    }
}

private extension EngineClient.LiveRoom {
    /// Archive search is deliberately broad: the operator may remember a room,
    /// participant, model, decision, or a phrase from the log rather than its title.
    func matchesArchiveSearch(_ query: String) -> Bool {
        var fields = [id, name]
        fields.append(contentsOf: participants.flatMap { participant in
            [participant.name, participant.persona, participant.model].compactMap { $0 }
        })
        fields.append(contentsOf: log.flatMap { message in
            [message.from, message.text] + message.to
        })
        fields.append(contentsOf: (decisions ?? []).flatMap { decision in
            [decision.key, decision.summary, decision.openedBy, decision.resolvedBy, decision.note]
                .compactMap { $0 }
        })
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
