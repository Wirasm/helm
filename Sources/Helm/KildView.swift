import AppKit
import SwiftUI

/// The kild observe/steer surface: engine health + live rooms (master) and the room
/// detail with a steering composer (detail). Polling for now; a later slice owns WS.
/// Attention-first, per the seed plan: open decisions outrank everything.
///
/// The sidebar stacks a collapsible Projects section (filter, not navigation) over a
/// Live/History room list. History serves the archive (`/api/rooms/archive`) into the
/// same detail view, read-only.
struct KildView: View {
    private enum RoomsTab {
        case live
        case history
    }

    private let engine = EngineClient()
    @State private var health: EngineClient.Health?
    @State private var rooms: [EngineClient.LiveRoom] = []
    @State private var archived: [EngineClient.ArchivedRoom] = []
    @State private var error: String?
    @State private var selection: String? = LaunchOptions.roomId
    @State private var tab: RoomsTab = .live

    // Project filter. `selectedProject == nil` = all projects. `projectWorktreeNames`
    // is the selected project's kild worktrees (from `/api/worktrees`) — the only link
    // from a worktree-room back to its project, since worktree dirs live under
    // `$KILD_HOME`, not under the project path.
    @State private var projects: [EngineClient.Project] = []
    @State private var selectedProject: EngineClient.Project?
    @State private var projectWorktreeNames: Set<String> = []
    @State private var projectsExpanded = true

    // "Add project…" inline form.
    @State private var addingProject = false
    @State private var newProjectName = ""
    @State private var newProjectPath = ""
    @State private var addProjectError: String?
    @State private var addingProjectInFlight = false

    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            // Engine header + Projects stay PINNED at the top; only the rooms list
            // below the Live/History tabs scrolls. The projects section scrolls
            // internally when very tall, capped at ~40% of the sidebar height.
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    if let error {
                        ContentUnavailableView(
                            "Engine unreachable",
                            systemImage: "bolt.slash",
                            description: Text(error)
                        )
                    } else {
                        projectsSection(maxHeight: max(120, geo.size.height * 0.4))
                        Divider()
                        tabPicker
                        roomList
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let room = shownRooms.first(where: { $0.id == selection }) {
                RoomDetailView(room: room, engine: engine, readOnly: tab == .history) {
                    await load()
                }
                // Stable identity per room: composer draft survives the 5s refresh,
                // resets when another room is selected.
                .id(room.id)
            } else {
                ContentUnavailableView(
                    "No room selected",
                    systemImage: "rectangle.on.rectangle.angled",
                    description: Text("Select a room to watch its log\(tab == .live ? " and steer" : "").")
                )
            }
        }
        .task { await load() }
        .onReceive(refresh) { _ in Task { await load() } }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(health != nil ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            Text(health != nil ? "kild engine · boot \(health!.bootId.prefix(8))" : "engine down")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(rooms.count) live")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    // MARK: projects — collapsible filter section

    /// Pinned when expanded; the rows scroll internally only once they outgrow
    /// `maxHeight` (ViewThatFits picks the plain stack while it still fits).
    private func projectsSection(maxHeight: CGFloat) -> some View {
        DisclosureGroup(isExpanded: $projectsExpanded) {
            ViewThatFits(in: .vertical) {
                projectRows
                ScrollView { projectRows }
            }
            .frame(maxHeight: maxHeight)
            .padding(.top, 4)
        } label: {
            Text("Projects")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var projectRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            projectRow(nil)
            ForEach(projects) { projectRow($0) }
            addProjectRow
        }
    }

    /// One selectable filter row; `nil` is the "All projects" default.
    private func projectRow(_ project: EngineClient.Project?) -> some View {
        let isSelected = selectedProject == project
        return Button {
            select(project)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: project == nil ? "square.grid.2x2" : "folder")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(project?.name ?? "All projects")
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                if let project {
                    Text(abbreviate(project.path))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .help(project?.path ?? "Show rooms from every project")
    }

    /// `~`-abbreviated project path, e.g. `~/Projects/mine/sild/kild`.
    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: add project — inline form, engine errors surfaced verbatim

    @ViewBuilder
    private var addProjectRow: some View {
        if addingProject {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Project name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitAddProject)
                HStack(spacing: 6) {
                    Button("Choose folder…", action: pickProjectFolder)
                    Text(newProjectPath.isEmpty ? "no folder chosen" : abbreviate(newProjectPath))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let addProjectError {
                    // The engine's own rejection text (duplicate name, not a
                    // directory) — shown verbatim, inline.
                    Label(addProjectError, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Add", action: submitAddProject)
                        .disabled(
                            addingProjectInFlight
                                || newProjectName.trimmingCharacters(in: .whitespaces).isEmpty
                                || newProjectPath.isEmpty
                        )
                    Button("Cancel", action: resetAddProject)
                        .disabled(addingProjectInFlight)
                }
                .controlSize(.small)
            }
            .padding(6)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 5))
        } else {
            Button {
                addingProject = true
            } label: {
                Label("Add project…", systemImage: "plus")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
        }
    }

    private func pickProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newProjectPath = url.path
        if newProjectName.trimmingCharacters(in: .whitespaces).isEmpty {
            newProjectName = url.lastPathComponent
        }
    }

    private func submitAddProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !newProjectPath.isEmpty, !addingProjectInFlight else { return }
        addingProjectInFlight = true
        addProjectError = nil
        Task {
            do {
                try await engine.addProject(name: name, path: newProjectPath)
                projects = try await engine.projects()
                resetAddProject()
            } catch let failure as EngineClient.Failure {
                addProjectError = failure.errorDescription
            } catch {
                addProjectError = error.localizedDescription
            }
            addingProjectInFlight = false
        }
    }

    private func resetAddProject() {
        addingProject = false
        newProjectName = ""
        newProjectPath = ""
        addProjectError = nil
    }

    private func select(_ project: EngineClient.Project?) {
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
        projectWorktreeNames = Set(trees.compactMap(\.name))
    }

    // MARK: room list — Live / History, filtered by the selected project

    private var tabPicker: some View {
        Picker("Rooms", selection: $tab) {
            Text("Live (\(rooms.count))").tag(RoomsTab.live)
            Text("History (\(archived.count))").tag(RoomsTab.history)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The current tab's rooms under the project filter. Live rooms sort
    /// attention-first (open decisions on top); history sorts newest-activity first.
    private var shownRooms: [EngineClient.LiveRoom] {
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

    @ViewBuilder
    private var roomList: some View {
        if shownRooms.isEmpty {
            ContentUnavailableView {
                Label(
                    tab == .live ? "No live rooms" : "No archived rooms",
                    systemImage: tab == .live ? "rectangle.on.rectangle.angled" : "archivebox"
                )
            } description: {
                if let selectedProject {
                    // Honest about the filter's limits: older archives persisted no
                    // cwd, so only their still-existing kild worktree can attribute
                    // them to a project.
                    Text(
                        tab == .history
                            ? "None attributable to \(selectedProject.name). Archived rooms without a saved cwd or live worktree only appear under All projects."
                            : "No live rooms in \(selectedProject.name)."
                    )
                }
            }
        } else {
            List(shownRooms, selection: $selection) { room in
                roomRow(room)
            }
            .listStyle(.inset)
        }
    }

    private func roomRow(_ room: EngineClient.LiveRoom) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(room.name).font(.body.weight(.semibold))
                // Display state only — a snapshot frozen at "running" means the
                // engine restarted under the room: interrupted. Plain closed
                // history is the norm and carries no badge.
                if tab == .history, room.archivedDisplayState != "closed" {
                    Text(room.archivedDisplayState)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if !room.openDecisions.isEmpty {
                    Label("\(room.openDecisions.count)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(room.openDecisions.map { "\($0.key): \($0.summary)" }.joined(separator: "\n"))
                }
            }
            Text(room.participants.map { p in
                p.model.map { "\(p.name):\($0)" } ?? p.name
            }.joined(separator: ", "))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            if let last = room.lastPost {
                Text("\(last.from) → \(last.to.joined(separator: ",")): \(last.text)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy Room ID") { Pasteboard.copy(room.id) }
        }
    }

    private func load() async {
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
        } catch {
            health = nil
            rooms = []
            archived = []
            projects = []
            self.error = "Start it: cd sild/kild/engine && bun run serve"
        }
    }
}
