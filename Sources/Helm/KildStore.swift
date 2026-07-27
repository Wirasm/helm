import Foundation

/// App-level kild engine state — the observe/steer data the whole frame shares.
/// One instance lives at RootView scope, fed by ONE 5s poller (RootView owns the
/// tick; never a poller per column): the sidebar column renders this store, the
/// right dock hosts the selected room's detail. Polling for now; a later slice
/// owns WS. Attention-first, per the seed plan: open decisions outrank everything.
@MainActor
final class KildStore: ObservableObject {
    enum RoomsTab {
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
        workspaces = WorkspacePersistence.load(from: defaults)
        selectedWorkspace = WorkspacePersistence.loadSelection(from: defaults, in: workspaces)
    }

    /// The current tab's rooms under the workspace filter. Live rooms sort
    /// attention-first (open decisions on top); the archive sorts newest-activity first.
    var shownRooms: [EngineClient.LiveRoom] {
        let source = tab == .live ? rooms : archived
        let filtered = selectedWorkspace.map { workspace in
            source.filter {
                $0.belongsToProject(at: workspace.path, worktreeNames: workspaceWorktreeNames)
            }
        } ?? source
        return tab == .live
            ? filtered.sorted {
                ($0.openDecisions.isEmpty ? 1 : 0, $0.name) < ($1.openDecisions.isEmpty ? 1 : 0, $1.name)
            }
            : filtered.sorted { ($0.log.last?.ts ?? 0) > ($1.log.last?.ts ?? 0) }
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
        if selectedWorkspace == workspace { select(nil) }
    }

    func select(_ workspace: Workspace?) {
        selectedWorkspace = workspace
        workspaceWorktreeNames = []
        selectedWorkspaceRoot = nil
        WorkspacePersistence.saveSelection(workspace, to: defaults)
        guard workspace != nil else { return }
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
        workspaceWorktreeNames = Set(trees.compactMap(\.worktree))
        guard selectedWorkspaceRoot == nil else { return }
        // git subprocess — off the main thread, once per selection, never per
        // render (the browser then matches stores against the root purely).
        let path = selectedWorkspace.path
        selectedWorkspaceRoot = await Task.detached {
            WorkspaceStore.repositoryRoot(for: path)
        }.value
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
