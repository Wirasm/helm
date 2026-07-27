import AppKit
import Inject
import SwiftUI
/// The observe/steer column of the frame: engine health header, a collapsible
/// Workspaces section (filter, not navigation), and the Live/History room list.
/// Pure rendering over `KildStore` — RootView owns the store, the 5s poll, and
/// the dock that hosts the selected room's detail.
///
/// The header + Workspaces stay PINNED at the top; only the rooms list below the
/// Live/History tabs scrolls. The workspaces section scrolls internally when very
/// tall, capped at ~40% of the column height.
struct SidebarColumn: View {
    /// Hot reload: `.enableInjection()` below redraws this view when
    /// InjectionNext swaps a recompiled build of it into the running app.
    /// Both are no-ops in release (docs/VENDORED.md).
    @ObserveInjection private var inject
    @ObservedObject var store: KildStore

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
                    workspacesSection(maxHeight: max(120, geo.size.height * 0.4))
                    Divider()
                    tabPicker
                    roomList
                }
            }
        }
        // ⌘⇧O — the menu/key monitor's "Open Workspace…"; the panel runs here
        // because this is the only view that owns the workspace list.
        .onReceive(NotificationCenter.default.publisher(for: .helmOpenWorkspace)) { _ in
            openWorkspace()
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

    // MARK: workspaces — collapsible filter section

    @State private var workspacesExpanded = true

    /// Pinned when expanded; the rows scroll internally only once they outgrow
    /// `maxHeight` (ViewThatFits picks the plain stack while it still fits).
    private func workspacesSection(maxHeight: CGFloat) -> some View {
        DisclosureGroup(isExpanded: $workspacesExpanded) {
            ViewThatFits(in: .vertical) {
                workspaceRows
                ScrollView { workspaceRows }
            }
            .frame(maxHeight: maxHeight)
            .padding(.top, 4)
        } label: {
            Text("Workspaces")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var workspaceRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            workspaceRow(nil)
            ForEach(store.workspaces) { workspace in
                workspaceRow(workspace)
                    .contextMenu {
                        // List removal only. Nothing was registered, so nothing is
                        // unregistered — the folder is untouched.
                        Button("Close Workspace") { store.close(workspace) }
                        Button("Copy Path") { Pasteboard.copy(workspace.path) }
                    }
            }
            openWorkspaceRow
        }
    }

    /// One selectable filter row; `nil` is the "All" default. A workspace is a
    /// folder, so two checkouts of one repo are two ordinary rows here.
    private func workspaceRow(_ workspace: Workspace?) -> some View {
        let isSelected = store.selectedWorkspace == workspace
        return Button {
            store.select(workspace)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: workspace == nil ? "square.grid.2x2" : "folder")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(workspace?.name ?? "All")
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                if let workspace {
                    Text(abbreviate(workspace.path))
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
        .help(workspace?.path ?? "Show rooms from every workspace")
    }

    /// `~`-abbreviated folder path, e.g. `~/Projects/mine/sild/kild`.
    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: open workspace — a folder picker, no registration, no error state

    private var openWorkspaceRow: some View {
        Button(action: openWorkspace) {
            Label("Open Workspace…", systemImage: "plus")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help("Open a folder as a workspace (⌘⇧O)")
    }

    /// Choosing the folder IS opening it — there is no name to invent and no engine
    /// round-trip that could fail, so this has no error path to surface.
    private func openWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to work in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.open(Workspace(url: url))
    }

    // MARK: room list — Live / History, filtered by the selected workspace

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
                if let selectedWorkspace = store.selectedWorkspace {
                    // Honest about the filter's limits: older archives persisted no
                    // cwd, so only their still-existing kild worktree can attribute
                    // them to a workspace.
                    Text(
                        store.tab == .history
                            ? "None attributable to \(selectedWorkspace.name). Archived rooms without a saved cwd or live worktree only appear under All."
                            : "No live rooms in \(selectedWorkspace.name)."
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
