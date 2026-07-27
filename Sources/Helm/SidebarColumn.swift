import Inject
import SwiftUI

enum SidebarPresentation {
    enum RoomStatus: Equatable {
        case needsYou
        case working
        case quiet(String)
    }

    enum ParticipantLiveness: Equatable {
        case attached
        case idle
        case reported
        case quiet
    }

    struct CollisionSummary: Equatable {
        let names: String
        let files: [String]

        var count: Int { files.count }
    }

    static func collisionSummary(_ collisions: [KildStore.RoomCollision]) -> CollisionSummary {
        CollisionSummary(
            names: collisions.map(\.room).joined(separator: ", "),
            files: Set(collisions.flatMap(\.files)).sorted()
        )
    }

    static func roomStatus(state: String?, hasOpenDecisions: Bool, live: Bool) -> RoomStatus {
        if hasOpenDecisions { return .needsYou }
        if live && state == "running" { return .working }
        return .quiet(state ?? "unknown")
    }

    static func participantLiveness(kind: String?, idle: Bool?, posted: Bool?) -> ParticipantLiveness {
        if kind == "attached" { return .attached }
        if idle == true { return .idle }
        if posted == true { return .reported }
        return .quiet
    }

    static func modelShortname(_ model: String?) -> String {
        model?.split(separator: "/").last.map(String.init) ?? "default"
    }
}

/// The observe column: the operator primitive, live rooms, and expandable history for
/// the active workspace. Detail and steering stay in the dock.
struct SidebarColumn: View {
    @ObserveInjection private var inject
    @ObservedObject var store: KildStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            operatorRow
            roomsHeader
            Divider()
            if let error = store.error {
                ContentUnavailableView(
                    "Engine unreachable",
                    systemImage: "bolt.slash",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.tab == .history {
                historySearch
                roomList
            } else {
                roomList
            }
            Divider()
            historyFooter
        }
        .enableInjection()
    }

    /// Deliberately inert: operator scheduling is undecided, so the UI says exactly that.
    private var operatorRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("start operator", systemImage: "chevron.right")
                .font(.callout.weight(.medium))
            Text("not spawned · parked primitive")
                .font(.caption.monospaced())
                .padding(.leading, 17)
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Operator spawning is not available")
    }

    private var roomsHeader: some View {
        Text("ROOMS · \(store.rooms.count) LIVE")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
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
        .padding(.vertical, 6)
    }

    private var historyFooter: some View {
        Button {
            store.tab = store.tab == .history ? .live : .history
        } label: {
            HStack(spacing: 6) {
                Image(systemName: store.tab == .history ? "chevron.down" : "chevron.right")
                    .font(.caption)
                Text("History · \(store.archived.count)")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .help(store.tab == .history ? "Collapse room history" : "Show room history")
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(store.shownRooms, selection: $store.selection) { room in
                roomRow(room)
            }
            .listStyle(.inset)
            .onExitCommand { store.selection = nil }
            // Global ⌘↑/⌘↓ remain terminal prompt jumps. Only an unmodified horizontal
            // move expands or collapses the List's current room selection.
            .onMoveCommand(perform: handleMoveCommand)
        }
    }

    @ViewBuilder
    private func roomRow(_ room: EngineClient.LiveRoom) -> some View {
        if store.tab == .history {
            archivedRoomRow(room)
        } else {
            liveRoomRow(room)
        }
    }

    private func liveRoomRow(_ room: EngineClient.LiveRoom) -> some View {
        let collisions = store.collisions(for: room.id)
        return VStack(alignment: .leading, spacing: 4) {
            roomTitle(room, expandable: true)
            gitLine(room, collisions: collisions)
            if store.expandedRooms.contains(room.id) {
                participantRows(room.participants)
            } else if let last = room.lastPost {
                Text(last.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(last.from) → \(last.to.joined(separator: ", ")): \(last.text)")
            }
        }
        .padding(.vertical, 4)
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

    private func archivedRoomRow(_ room: EngineClient.LiveRoom) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            roomTitle(room, expandable: false)
            Text(participantSummary(room.participants))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(participantDetails(room.participants))
            if let last = room.lastPost {
                Text(last.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy Room ID") { Pasteboard.copy(room.id) }
        }
    }

    private func roomTitle(_ room: EngineClient.LiveRoom, expandable: Bool) -> some View {
        HStack(spacing: 5) {
            if expandable {
                Button { toggleRoom(room.id) } label: {
                    Image(systemName: store.expandedRooms.contains(room.id) ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .frame(width: 10)
                }
                .buttonStyle(.plain)
                .help(store.expandedRooms.contains(room.id) ? "Collapse participants" : "Show participants")
            }
            Text(room.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            statusChip(room)
        }
    }

    private func statusChip(_ room: EngineClient.LiveRoom) -> some View {
        let displayState = store.tab == .history ? room.archivedDisplayState : room.state
        let status = SidebarPresentation.roomStatus(
            state: displayState,
            hasOpenDecisions: !room.openDecisions.isEmpty,
            live: store.tab == .live
        )
        let label: String
        let color: Color
        switch status {
        case .needsYou: (label, color) = ("needs you", .orange)
        case .working: (label, color) = ("working", .green)
        case let .quiet(state): (label, color) = (state, .secondary)
        }
        return Text(label)
            .font(.caption2.monospaced().weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func gitLine(
        _ room: EngineClient.LiveRoom,
        collisions: [KildStore.RoomCollision]
    ) -> some View {
        let worktree = room.worktree ?? "main checkout"
        let collision = SidebarPresentation.collisionSummary(collisions)
        return HStack(spacing: 5) {
            Text("⌂ \(worktree)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(room.git?.path ?? worktree)
            if !collisions.isEmpty {
                Text("⇢ \(collision.names) · \(collision.count)")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(collision.files.joined(separator: "\n"))
                    .layoutPriority(1)
            }
        }
        .font(.caption.monospaced())
    }

    private func participantRows(_ participants: [EngineClient.Participant]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(participants.enumerated()), id: \.offset) { _, participant in
                HStack(spacing: 4) {
                    Text("\(participant.persona ?? participant.name) · \(SidebarPresentation.modelShortname(participant.model))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(participant.model ?? "default model")
                    Spacer(minLength: 3)
                    participantLiveness(participant)
                }
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 1)
                .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private func participantLiveness(_ participant: EngineClient.Participant) -> some View {
        switch SidebarPresentation.participantLiveness(
            kind: participant.kind,
            idle: participant.idle,
            posted: participant.posted
        ) {
        case .attached:
            Text("attached")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        case .idle:
            Text("idle")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        case .reported:
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .accessibilityLabel("reported")
        case .quiet:
            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 6, height: 6)
                .accessibilityLabel("quiet")
        }
    }

    private func toggleRoom(_ id: String) {
        if store.expandedRooms.contains(id) {
            store.expandedRooms.remove(id)
        } else {
            store.expandedRooms.insert(id)
        }
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        guard store.tab == .live, let selection = store.selection else { return }
        switch direction {
        case .right: store.expandedRooms.insert(selection)
        case .left: store.expandedRooms.remove(selection)
        default: break
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
