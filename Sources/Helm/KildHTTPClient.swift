import Foundation

/// `KildAPI` over the engine's REST surface on loopback.
///
/// Deliberately dumb: one method, one request, no caching, no retries, no request
/// coalescing. Cadence and staleness are decisions the store makes with the whole picture
/// in view; a client that made them privately would be a second source of truth whose
/// disagreements are invisible from the UI.
struct KildHTTPClient: KildAPI {
    var baseURL = URL(string: "http://127.0.0.1:4517")!

    /// Injectable for tests via `URLProtocol` stubs. Named `urlSession` because "session"
    /// unqualified belongs to kild and pi sessions, which are a different thing entirely.
    var urlSession: URLSession = .shared

    /// The bearer token from `POST /api/kilds/:id/agents/attach`, when helm holds one.
    ///
    /// Attribution depends on it: the engine writes `from` off the credential, and a request
    /// without one is recorded unattributed. That is not cosmetic — an unattributed message
    /// is indistinguishable from the operator's own, so an agent's opinion can be read as an
    /// instruction from the human. Worth carrying even though this is loopback and the token
    /// is readable by any local process: it is attribution, not security.
    var token: String?

    // MARK: - Reads

    func health() async throws -> Health {
        try await get(path("api", "health"))
    }

    func kilds() async throws -> [Kild] {
        try await get(path("api", "kilds"))
    }

    func kildsStatus() async throws -> [Kild] {
        try await get(path("api", "kilds", "status"))
    }

    func archive() async throws -> [ArchivedKild] {
        try await get(path("api", "kilds", "archive"))
    }

    func messages(in kild: Kild.ID, since seq: Int? = nil) async throws -> [Message] {
        try await get(
            path("api", "kilds", kild, "messages"),
            query: seq.map { [URLQueryItem(name: "since", value: String($0))] } ?? [])
    }

    func personas() async throws -> [String] {
        try await get(path("api", "personas"))
    }

    func landDryRun(_ kild: Kild.ID) async throws -> LandReport {
        try await get(path("api", "kilds", kild, "land"))
    }

    // MARK: - Writes

    func send(to recipients: [String], text: String, in kild: Kild.ID) async throws {
        try await send(
            "POST", path("api", "kilds", kild, "messages"),
            body: ["to": recipients, "text": text])
    }

    func land(_ kild: Kild.ID) async throws -> LandReport {
        try await send("POST", path("api", "kilds", kild, "land"))
    }

    func delete(_ kild: Kild.ID) async throws {
        try await send("DELETE", path("api", "kilds", kild))
    }

    func stop(_ kild: Kild.ID) async throws {
        try await send("POST", path("api", "kilds", kild, "stop"))
    }

    func stopAgent(_ handle: String, in kild: Kild.ID) async throws {
        try await send("DELETE", path("api", "kilds", kild, "agents", handle))
    }

    // MARK: - Transport

    /// Build a path from identifiers that are not ours to trust.
    ///
    /// An orphan kild is addressed by its worktree name — arbitrary text read off disk — and
    /// a handle is whatever an agent registered with. Each segment is encoded exactly once,
    /// with `/` **excluded** from the allowed set: an identifier containing a slash is one
    /// identifier, not two path components, and letting it split the path would address a
    /// different resource than the caller named.
    ///
    /// Encoding here rather than in `URL.appending(path:)` is deliberate — that method
    /// re-encodes an already-encoded string, turning `%20` into `%2520`.
    private func path(_ segments: String...) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return "/" + segments
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
    }

    /// Assemble the URL with the query as structured items rather than string-appended.
    ///
    /// `URL.appending(path:)` percent-encodes `?`, so a query written into the path string
    /// silently becomes part of the path — the engine then sees no cursor and returns the
    /// whole log, which reads as "there was nothing new" rather than as an error.
    private func url(_ path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    private func request(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]?
    ) throws -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Run a request and surface the engine's own words when it refuses.
    ///
    /// The `{"error": …}` body is checked before the status code, because it is the more
    /// useful of the two and the engine sends it on every deliberate refusal.
    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = object["error"] as? String
            {
                throw KildAPIError.engine(message)
            }
            throw KildAPIError.http(code)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw KildAPIError.decoding(String(describing: error))
        }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws
        -> T
    {
        try decode(try await perform(try request("GET", path, query: query, body: nil)))
    }

    private func send<T: Decodable>(
        _ method: String, _ path: String, body: [String: Any]? = nil
    ) async throws -> T {
        try decode(try await perform(try request(method, path, body: body)))
    }

    /// For writes whose body helm does not read. The request still has to complete, and a
    /// refusal still has to throw — discarding the response is not the same as ignoring it.
    private func send(_ method: String, _ path: String, body: [String: Any]? = nil)
        async throws
    {
        _ = try await perform(try request(method, path, body: body))
    }
}
