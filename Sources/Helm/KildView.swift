import SwiftUI

/// Spike-grade kild view: engine health + live rooms with open-decision badges.
/// Polling for now; the real view subscribes to the engine WS. Layout follows the
/// seed plan (kild/docs/ui-plan.md): attention first — open decisions outrank all.
struct KildView: View {
    private let engine = EngineClient()
    @State private var health: EngineClient.Health?
    @State private var rooms: [EngineClient.LiveRoom] = []
    @State private var error: String?

    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
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
                roomList
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
            Text("\(rooms.count) live rooms")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var roomList: some View {
        // Attention-first: rooms with open decisions sort to the top.
        let sorted = rooms.sorted {
            ($0.openDecisions.isEmpty ? 1 : 0, $0.name) < ($1.openDecisions.isEmpty ? 1 : 0, $1.name)
        }
        return List(sorted) { room in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(room.name).font(.headline)
                    Text(room.participants.map { p in
                        p.model.map { "\(p.name):\($0)" } ?? p.name
                    }.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    Spacer()
                    if !room.openDecisions.isEmpty {
                        Label("\(room.openDecisions.count)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(room.openDecisions.map { "\($0.key): \($0.summary)" }.joined(separator: "\n"))
                    }
                }
                ForEach(room.openDecisions, id: \.key) { decision in
                    Text("needs-decision[\(decision.key)]: \(decision.summary)")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let last = room.lastPost {
                    Text("\(last.from) → \(last.to.joined(separator: ",")): \(last.text)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.inset)
    }

    private func load() async {
        do {
            health = try await engine.health()
            rooms = try await engine.liveRooms()
            error = nil
        } catch {
            health = nil
            rooms = []
            self.error = "Start it: cd sild/kild/engine && bun run serve"
        }
    }
}
