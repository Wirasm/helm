import AppKit
import Inject
import SwiftUI
/// The observe/steer column of the frame: engine health header, a collapsible
/// Projects section (filter, not navigation), and the Live/History room list.
/// Pure rendering over `KildStore` — RootView owns the store, the 5s poll, and
/// the dock that hosts the selected room's detail.
///
/// The header + Projects stay PINNED at the top; only the rooms list below the
/// Live/History tabs scrolls. The projects section scrolls internally when very
/// tall, capped at ~40% of the column height.
struct SidebarColumn: View {
    /// Hot reload: `.enableInjection()` below redraws this view when
    /// InjectionNext swaps a recompiled build of it into the running app.
    /// Both are no-ops in release (docs/VENDORED.md).
    @ObserveInjection private var inject
    @ObservedObject var store: KildStore

    // "Add project…" inline form.
    @State private var addingProject = false
    @State private var newProjectName = ""
    @State private var newProjectPath = ""
    @State private var addProjectError: String?
    @State private var addingProjectInFlight = false

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if let error = store.error {
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
        .enableInjection()
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(store.health != nil ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            Text(store.health != nil
                ? "kild engine · boot \(store.health!.bootId.prefix(8))"
                : "engine down")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(store.rooms.count) live")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    // MARK: projects — collapsible filter section

    @State private var projectsExpanded = true

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
            ForEach(store.projects) { projectRow($0) }
            addProjectRow
        }
    }

    /// One selectable filter row; `nil` is the "All projects" default.
    private func projectRow(_ project: EngineClient.Project?) -> some View {
        let isSelected = store.selectedProject == project
        return Button {
            store.select(project)
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
                try await store.engine.addProject(name: name, path: newProjectPath)
                store.projects = try await store.engine.projects()
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

    // MARK: room list — Live / History, filtered by the selected project

    private var tabPicker: some View {
        Picker("Rooms", selection: $store.tab) {
            Text("Live (\(store.rooms.count))").tag(KildStore.RoomsTab.live)
            Text("History (\(store.archived.count))").tag(KildStore.RoomsTab.history)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var roomList: some View {
        if store.shownRooms.isEmpty {
            ContentUnavailableView {
                Label(
                    store.tab == .live ? "No live rooms" : "No archived rooms",
                    systemImage: store.tab == .live ? "rectangle.on.rectangle.angled" : "archivebox"
                )
            } description: {
                if let selectedProject = store.selectedProject {
                    // Honest about the filter's limits: older archives persisted no
                    // cwd, so only their still-existing kild worktree can attribute
                    // them to a project.
                    Text(
                        store.tab == .history
                            ? "None attributable to \(selectedProject.name). Archived rooms without a saved cwd or live worktree only appear under All projects."
                            : "No live rooms in \(selectedProject.name)."
                    )
                }
            }
        } else {
            List(store.shownRooms, selection: $store.selection) { room in
                roomRow(room)
            }
            .listStyle(.inset)
            // Esc while the list has focus deselects the room; the dock then
            // falls back to the artifact (if open) or closes.
            .onExitCommand { store.selection = nil }
        }
    }

    private func roomRow(_ room: EngineClient.LiveRoom) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(room.name).font(.body.weight(.semibold))
                // Display state only — a snapshot frozen at "running" means the
                // engine restarted under the room: interrupted. A plain closed
                // room is the archive's norm and carries no badge.
                if store.tab == .history, room.archivedDisplayState != "closed" {
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
}
