import Inject
import SwiftUI

/// The observe column: engine health and rooms for the active workspace. Workspace
/// switching belongs to WorkspaceBar; this column stays scan-first and rooms-only.
struct SidebarColumn: View {
    @ObserveInjection private var inject
    @ObservedObject var store: KildStore

    var body: some View {
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
                tabPicker
                if store.tab == .history { historySearch }
                roomList
            }
        }
        .enableInjection()
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(store.health != nil ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            Text(store.health != nil ? "kild engine" : "engine down")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(store.rooms.count) live")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

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

    private var historySearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search archived rooms", text: $store.historyQuery)
                .textFieldStyle(.plain)
            if !store.historyQuery.isEmpty {
                Button { store.historyQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear archive search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var roomList: some View {
        if store.shownRooms.isEmpty {
            ContentUnavailableView {
                let searchingArchive = store.tab == .history && !store.historyQuery.isEmpty
                Label(
                    searchingArchive
                        ? "No matching archived rooms"
                        : (store.tab == .live ? "No live rooms" : "No archived rooms"),
                    systemImage: searchingArchive
                        ? "magnifyingglass"
                        : (store.tab == .live ? "rectangle.on.rectangle.angled" : "archivebox")
                )
            } description: {
                if store.tab == .history && !store.historyQuery.isEmpty {
                    Text("Try a room, participant, model, decision, or phrase from a post.")
                } else if let workspace = store.selectedWorkspace {
                    Text("No rooms in \(workspace.name).")
                }
            }
        } else {
            List(store.shownRooms, selection: $store.selection) { room in
                roomRow(room)
            }
            .listStyle(.inset)
            .onExitCommand { store.selection = nil }
        }
    }

    /// With workspaces now above the frame, each room gets a stable three-line
    /// maximum: identity, participant handles, and one post preview. Full model
    /// identity remains in the detail chips and this row's hover help.
    private func roomRow(_ room: EngineClient.LiveRoom) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(room.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if store.tab == .history, room.archivedDisplayState != "closed" {
                    Text(room.archivedDisplayState)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(participantSummary(room.participants))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(participantDetails(room.participants))
            if let last = room.lastPost {
                Text("\(last.from) → \(last.to.joined(separator: ",")): \(last.text)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        // Attention changes the existing row: an open decision gives it an edge,
        // never a badge, count, or additional indicator.
        .overlay(alignment: .leading) {
            if !room.openDecisions.isEmpty {
                Rectangle()
                    .fill(.orange)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                    .help(room.openDecisions.map { "\($0.key): \($0.summary)" }.joined(separator: "\n"))
            }
        }
        .contextMenu {
            Button("Copy Room ID") { Pasteboard.copy(room.id) }
        }
    }

    private func participantSummary(_ participants: [EngineClient.Participant]) -> String {
        participants.map { "@\($0.name)" }.joined(separator: " · ")
    }

    private func participantDetails(_ participants: [EngineClient.Participant]) -> String {
        participants.map { participant in
            participant.model.map { "@\(participant.name) · \($0)" } ?? "@\(participant.name)"
        }.joined(separator: "\n")
    }
}
