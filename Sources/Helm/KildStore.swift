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

    let engine = EngineClient()

    @Published var health: EngineClient.Health?
    @Published var rooms: [EngineClient.LiveRoom] = []
    @Published var archived: [EngineClient.ArchivedRoom] = []
    @Published var projects: [EngineClient.Project] = []
    @Published var error: String?

    /// The selected room id — the sidebar's list drives it, the dock renders it
    /// (a selected room wins the dock over any open artifact).
    @Published var selection: String? = LaunchOptions.roomId
    @Published var tab: RoomsTab = .live
    // A --room launch lands on History when the id isn't live at first load; the
    // load() pass below corrects the tab once data arrives (testability seam).
    private var launchRoomResolved = LaunchOptions.roomId == nil

    // Project filter. `selectedProject == nil` = all projects. `projectWorktreeNames`
    // is the selected project's kild worktrees (from `/api/worktrees`) — the only link
    // from a worktree-room back to its project, since worktree dirs live under
    // `$KILD_HOME`, not under the project path.
    @Published var selectedProject: EngineClient.Project?
    @Published private(set) var projectWorktreeNames: Set<String> = []

    /// The current tab's rooms under the project filter. Live rooms sort
    /// attention-first (open decisions on top); the archive sorts newest-activity first.
    var shownRooms: [EngineClient.LiveRoom] {
        let source = tab == .live ? rooms : archived
        let filtered = selectedProject.map { project in
            source.filter {
                $0.belongsToProject(at: project.path, worktreeNames: projectWorktreeNames)
            }
        } ?? source
        return tab == .live
            ? filtered.sorted {
                ($0.openDecisions.isEmpty ? 1 : 0, $0.name) < ($1.openDecisions.isEmpty ? 1 : 0, $1.name)
            }
            : filtered.sorted { ($0.log.last?.ts ?? 0) > ($1.log.last?.ts ?? 0) }
    }

    /// The dock's room tenant: the selection resolved against the SHOWN list, so
    /// a room hidden by the project filter yields the dock back to the artifact.
    var selectedRoom: EngineClient.LiveRoom? {
        shownRooms.first { $0.id == selection }
    }

    func select(_ project: EngineClient.Project?) {
        selectedProject = project
        projectWorktreeNames = []
        guard project != nil else { return }
        Task { await refreshWorktreeNames() }
    }

    /// The selected project's kild worktree names — fetched best-effort (a project
    /// that isn't a git repo legitimately 400s; that only disables worktree matching).
    private func refreshWorktreeNames() async {
        guard let selectedProject else { return }
        let trees = (try? await engine.worktrees(project: selectedProject.name)) ?? []
        projectWorktreeNames = Set(trees.compactMap(\.worktree))
    }

    func load() async {
        do {
            health = try await engine.health()
            rooms = try await engine.liveRooms()
            archived = try await engine.archivedRooms()
            projects = try await engine.projects()
            if let current = selectedProject, !projects.contains(current) {
                // The registered project vanished (edited out-of-band) — fall back
                // to All rather than filtering on a ghost.
                selectedProject = nil
                projectWorktreeNames = []
            }
            await refreshWorktreeNames()
            error = nil
            if !launchRoomResolved, let id = selection {
                if archived.contains(where: { $0.id == id }) { tab = .history }
                launchRoomResolved = true
            }
        } catch {
            health = nil
            rooms = []
            archived = []
            projects = []
            self.error = "Start it: cd sild/kild/engine && bun run serve"
        }
    }
}
