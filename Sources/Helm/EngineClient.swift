import Foundation

/// Thin typed client for the kild engine's REST surface — the ONLY backend contract
/// helm has. Read-only for the spike (health + live rooms); posting/steering comes
/// with the real kild view.
struct EngineClient: Sendable {
    var baseURL = URL(string: "http://127.0.0.1:4517")!

    struct Health: Decodable {
        let ok: Bool
        let bootId: String
    }

    struct Participant: Decodable {
        let name: String
        let agent: String?
        let model: String?
        let piSessionFile: String?
    }

    struct Decision: Decodable {
        let key: String
        let summary: String
        let openedBy: String
        let resolvedAt: Double?
    }

    struct Message: Decodable {
        let from: String
        let to: [String]
        let text: String
        let system: Bool?
        let implicit: Bool?
    }

    struct LiveRoom: Decodable, Identifiable {
        let id: String
        let name: String
        let state: String?
        let participants: [Participant]
        let log: [Message]
        let decisions: [Decision]?

        var openDecisions: [Decision] {
            (decisions ?? []).filter { $0.resolvedAt == nil }
        }

        var lastPost: Message? {
            log.last { $0.system != true }
        }
    }

    func health() async throws -> Health {
        try await get("/api/health")
    }

    func liveRooms() async throws -> [LiveRoom] {
        try await get("/api/rooms/live")
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: path))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
