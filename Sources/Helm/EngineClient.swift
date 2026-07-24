import Foundation

/// Thin typed client for the kild engine's REST surface — the ONLY backend contract
/// helm has. Reads (health, live rooms, archived rooms, projects, worktrees) plus
/// steering actions: posting into a room and registering a project.
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

    /// A registered project — a directory agents work in (`~/.config/kild/projects.json`).
    struct Project: Decodable, Identifiable, Hashable {
        let name: String
        let path: String
        var id: String { name }
    }

    /// A kild-managed git worktree of one project's repo (`GET /api/worktrees?project=`).
    /// `name` is the room-facing worktree handle (the `kild/<name>` branch minus prefix)
    /// — the engine-truth link from a room's `worktree` field back to its project.
    struct Worktree: Decodable {
        let branch: String
        let path: String
        let name: String?
    }

    struct Participant: Decodable {
        let name: String
        let agent: String?
        let model: String?
        /// Durable pi resume handle (`pi --session <file>`) — set once the session
        /// reported it; survives into the archive.
        let piSessionFile: String?

        /// Terminal command reopening this participant's session — nil without a handle.
        var resumeCommand: String? {
            piSessionFile.map { "pi --session \($0)" }
        }
    }

    struct Decision: Decodable {
        let key: String
        let summary: String
        let openedBy: String
        let resolvedBy: String?
        let resolvedAt: Double?
        /// The resolution text of the closing `resolved[key]: …` post.
        let note: String?
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

    /// The slice of the engine's `WorkstreamGitStatus` helm consumes: `path` is the
    /// effective workstream dir — the room's cwd, or its shared worktree dir (under
    /// `$KILD_HOME/worktrees`) when one is set. It is the project-filter key for live
    /// rooms; the remaining git fields stay undecoded until a view renders them.
    struct GitStatus: Decodable {
        let path: String
    }

    struct LiveRoom: Decodable, Identifiable {
        let id: String
        let name: String
        let state: String?
        /// The room's working directory. Serves the archive's project attribution
        /// (kild #669): archived rooms persist no git state, but do keep their cwd.
        let cwd: String?
        /// Shared worktree name (`kild/<worktree>` branch), when the room has one.
        let worktree: String?
        let participants: [Participant]
        let log: [Message]
        let decisions: [Decision]?
        /// Live rooms only — the archive persists no git state.
        let git: GitStatus?

        var openDecisions: [Decision] {
            (decisions ?? []).filter { $0.resolvedAt == nil }
        }

        var lastPost: Message? {
            log.last { $0.system != true }
        }

        /// State to DISPLAY for an archived room — never the raw snapshot state.
        /// An engine restart archives still-"running" rooms with that state frozen
        /// in the snapshot; for history it means the room was interrupted, never
        /// that it is running.
        var archivedDisplayState: String {
            switch state {
            case nil, "closed": "closed"
            case "running": "interrupted"
            case let .some(other): other
            }
        }

        /// Does this room's workstream live under `projectPath`? True when the
        /// effective dir is inside the project, or when the room's worktree name is
        /// one of the project's kild worktrees (`worktreeNames`, from
        /// `/api/worktrees` — worktree dirs live under `$KILD_HOME`, so the path
        /// test alone cannot attribute them). The effective dir is `git.path` for
        /// live rooms; archived rooms carry no git, so their persisted `cwd`
        /// (kild #669) takes over, with the worktree-name test as the fallback for
        /// older archives without one.
        func belongsToProject(at projectPath: String, worktreeNames: Set<String>) -> Bool {
            if let worktree, worktreeNames.contains(worktree) { return true }
            guard let path = git?.path ?? cwd else { return false }
            let root = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
            return path == root || path.hasPrefix(root + "/")
        }
    }

    /// `/api/rooms/archive` serves the same shape as a live room minus `git`/`totals`
    /// but plus a persisted `cwd` (see the engine's `ArchivedRoom` vs
    /// `LiveRoomStatus`), so one struct decodes both.
    typealias ArchivedRoom = LiveRoom

    func health() async throws -> Health {
        try await get("/api/health")
    }

    func liveRooms() async throws -> [LiveRoom] {
        try await get("/api/rooms/live")
    }

    /// Past rooms recovered from disk — read-only history (state closed/halted).
    func archivedRooms() async throws -> [ArchivedRoom] {
        try await get("/api/rooms/archive")
    }

    func projects() async throws -> [Project] {
        try await get("/api/projects")
    }

    /// The project's kild worktrees — accepts a registered name or a raw path.
    func worktrees(project: String) async throws -> [Worktree] {
        try await get("/api/worktrees", query: [URLQueryItem(name: "project", value: project)])
    }

    /// Register a project directory with the engine. The engine validates (existing
    /// directory, unique name) and rejects with its own `{error}` text, surfaced as
    /// `Failure.engine` for inline display.
    @discardableResult
    func addProject(name: String, path: String) async throws -> Project {
        struct Body: Encodable {
            let name: String
            let path: String
        }
        var request = URLRequest(url: baseURL.appending(path: "/api/projects"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(name: name, path: path))
        let (data, response) = try await session.data(for: request)
        return try decode(data, response)
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

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        let (data, response) = try await session.data(from: url)
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
