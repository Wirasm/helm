import Foundation

/// Thin typed client for the kild engine's REST surface — the ONLY backend contract
/// helm has. Reads (health + live rooms) plus the first steering action: posting into
/// a room as the human operator.
struct EngineClient: Sendable {
    var baseURL = URL(string: "http://127.0.0.1:4517")!
    /// Injectable for tests (URLProtocol stubs); defaults to the shared session.
    var session: URLSession = .shared

    /// Engine-domain failures, kept separate from transport errors so the UI can
    /// surface the engine's own rejection text (e.g. "no such participant: @x …").
    enum Failure: Error, Equatable, LocalizedError {
        /// The engine rejected the request and said why (`{error}` body).
        case engine(String)
        /// Non-200 without a readable engine error body.
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case let .engine(message): message
            case let .badResponse(code): "engine returned HTTP \(code)"
            }
        }
    }

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

    struct Message: Decodable, Identifiable {
        let id: String
        let from: String
        let to: [String]
        let text: String
        /// Epoch millis, stamped by the engine on receipt.
        let ts: Double
        let system: Bool?
        let implicit: Bool?

        /// Engine notices + auto-posted turn replies — visually muted in the log.
        var isMuted: Bool { system == true || implicit == true }

        var date: Date { Date(timeIntervalSince1970: ts / 1000) }
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

    /// Post into a room as the human operator (no `from`/`sessionId` → the engine
    /// attributes the post to the human; actor identity is engine-derived). Returns
    /// the engine's confirmation line. Steering only — helm adds no semantics: a
    /// decision resolution is just a `resolved[key]: …` post.
    @discardableResult
    func post(inRoom roomId: String, text: String) async throws -> String {
        struct Body: Encodable { let text: String }
        struct Reply: Decodable { let ok: Bool; let message: String? }
        var request = URLRequest(url: baseURL.appending(path: "/api/rooms/\(roomId)/post"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(text: text))
        let (data, response) = try await session.data(for: request)
        let reply: Reply = try decode(data, response)
        return reply.message ?? "posted"
    }

    private struct Rejection: Decodable { let error: String }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await session.data(from: baseURL.appending(path: path))
        return try decode(data, response)
    }

    /// Shared response handling: 200 → decode T; otherwise prefer the engine's own
    /// `{error}` text over a bare status code.
    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw Failure.badResponse(-1)
        }
        guard http.statusCode == 200 else {
            if let rejection = try? JSONDecoder().decode(Rejection.self, from: data) {
                throw Failure.engine(rejection.error)
            }
            throw Failure.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
