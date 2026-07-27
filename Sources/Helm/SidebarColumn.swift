import Inject
import SwiftUI

/// The observe column: engine health and rooms for the active workspace.
struct SidebarColumn: View {
    @ObserveInjection private var inject
    @ObservedObject var store: KildStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error = store.error {
                ContentUnavailableView("Engine unreachable", systemImage: "bolt.slash", description: Text(error))
            } else {
                tabPicker
                roomList
            }
        }.enableInjection()
    }

    private var header: some View {
        HStack {
            Circle().fill(store.health != nil ? Color.green : Color.red).frame(width: 9, height: 9)
            Text(store.health != nil ? "kild engine · boot \(store.health!.bootId.prefix(8))" : "engine down")
                .font(.callout.monospaced()).foregroundStyle(.secondary)
            Spacer()
            Text("\(store.rooms.count) live").font(.callout).foregroundStyle(.secondary)
        }.padding(10)
    }

    private var tabPicker: some View {
        Picker("Rooms", selection: $store.tab) {
            Text("Live (\(store.rooms.count))").tag(KildStore.RoomsTab.live)
            Text("History (\(store.archived.count))").tag(KildStore.RoomsTab.history)
        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder private var roomList: some View {
        if store.shownRooms.isEmpty {
            ContentUnavailableView {
                Label(store.tab == .live ? "No live rooms" : "No archived rooms", systemImage: store.tab == .live ? "rectangle.on.rectangle.angled" : "archivebox")
            } description: {
                if let workspace = store.selectedWorkspace { Text("No rooms in \(workspace.name).") }
            }
        } else {
            List(store.shownRooms, selection: $store.selection) { room in roomRow(room) }
                .listStyle(.inset).onExitCommand { store.selection = nil }
        }
    }

    private func roomRow(_ room: EngineClient.LiveRoom) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(room.name).font(.body.weight(.semibold))
                Spacer()
                if !room.openDecisions.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            Text(room.participants.map { participant in
                participant.model.map { "\(participant.name):\($0)" } ?? participant.name
            }.joined(separator: ", "))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if let last = room.lastPost { Text("\(last.from) → \(last.to.joined(separator: ",")): \(last.text)").font(.callout).foregroundStyle(.secondary).lineLimit(2) }
        }.padding(.vertical, 4).contextMenu { Button("Copy Room ID") { Pasteboard.copy(room.id) } }
    }
}
