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

    func transcript(of handle: String, in kild: Kild.ID) async throws -> AgentTranscript {
        try await get(path("api", "kilds", kild, "agents", handle, "transcript"))
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

    /// A refused merge returns 409 carrying the full report, so that 409 is decoded rather
    /// than thrown — the gate needs the commits, files and conflicts to explain itself, and
    /// `error` alone would not carry them.
    ///
    /// `answerKey: "wouldMerge"` is what keeps that from swallowing the *other* 409 this
    /// route emits: an unresolvable target (an archived kild, say) returns a bare
    /// `{"error", "code"}`, which must stay an error so the engine's message survives.
    func land(_ kild: Kild.ID) async throws -> LandReport {
        try await send(
            "POST", path("api", "kilds", kild, "land"), accepting: [409],
            answerKey: "wouldMerge", unknownVerb: "land")
    }

    @discardableResult
    func delete(_ kild: Kild.ID, force: Bool = false) async throws -> DisposalReport {
        // `force` is sent only when true. The engine validates the value strictly — it 400s
        // on anything but "true"/"false" — so an always-present parameter would be one more
        // thing to get wrong for no gain.
        try await send(
            "DELETE", path("api", "kilds", kild),
            query: force ? [URLQueryItem(name: "force", value: "true")] : [],
            unknownVerb: "disposal")
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
        return "/"
            + segments
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
    ///
    /// `answerKey` names a field that marks a non-2xx body as *the answer* rather than an
    /// error. Present → return the body; absent → treat it as a refusal as usual.
    ///
    /// `POST /land` needs this, and needs it discriminated rather than blanket-accepted,
    /// because it returns 409 from two places that look nothing alike:
    ///
    /// - a refused merge — the **full report**, same fields as success plus the reason;
    /// - an unresolvable target — a **bare** `{"error", "code"}`, e.g. addressing a kild
    ///   that has since been archived.
    ///
    /// Accepting every 409 fed the bare one to `LandReport`'s decoder, which threw, and the
    /// engine's genuinely useful message — *"kild X is archived … address its tree as 'Y'"*
    /// — was replaced by an opaque decoding error that reads as a wire bug rather than as
    /// "you picked the wrong target". Keying on a field the full report always carries and
    /// the bare refusal never does keeps both paths honest.
    ///
    /// Note the discriminator cannot be `error`: the full report carries one too, since a
    /// refused merge has a reason.
    private func perform(
        _ request: URLRequest, accepting: Set<Int> = [], answerKey: String? = nil,
        unknownVerb: String? = nil
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            // A raw URLError leaking to callers is what made a timeout indistinguishable
            // from a refusal. `unknownVerb` is set only by mutations that cannot be safely
            // repeated — for those, a timeout is NOT a failure: the engine may have finished
            // the work after we stopped listening.
            let timedOut = (error as? URLError)?.code == .timedOut
            if timedOut, let unknownVerb {
                throw KildAPIError.outcomeUnknown(verb: unknownVerb)
            }
            throw KildAPIError.unreachable(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { return data }

        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Accepted only when the body PROVES it is the answer. `answerKey` is required for
        // that proof, so there is deliberately no "accept any body at this status" path: a
        // status code alone cannot distinguish a full report from a bare refusal, which is
        // exactly the confusion that ate the engine's message once already.
        if accepting.contains(code), let answerKey, object?[answerKey] != nil {
            return data
        }
        if let message = object?["error"] as? String {
            throw KildAPIError.engine(message)
        }
        throw KildAPIError.http(code)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw KildAPIError.decoding(String(describing: error))
        }
    }

    private func get<T: Decodable>(
        _ path: String, query: [URLQueryItem] = []
    ) async throws
        -> T
    {
        try decode(try await perform(try request("GET", path, query: query, body: nil)))
    }

    private func send<T: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [],
        body: [String: Any]? = nil, accepting: Set<Int> = [], answerKey: String? = nil,
        unknownVerb: String? = nil
    ) async throws -> T {
        try decode(
            try await perform(
                try request(method, path, query: query, body: body), accepting: accepting,
                answerKey: answerKey, unknownVerb: unknownVerb))
    }

    /// For writes whose body helm does not read. The request still has to complete, and a
    /// refusal still has to throw — discarding the response is not the same as ignoring it.
    private func send(
        _ method: String, _ path: String, body: [String: Any]? = nil
    )
        async throws
    {
        _ = try await perform(try request(method, path, body: body))
    }
}
