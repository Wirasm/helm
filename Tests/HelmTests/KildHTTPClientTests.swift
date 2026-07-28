import XCTest

@testable import Helm

/// The REST client, against `StubURLProtocol` — no engine, no network.
///
/// These assert the two things a thin client can get wrong: that it calls the right route
/// with the right shape, and that it surfaces a refusal rather than swallowing it. Anything
/// beyond that (cadence, caching, staleness) deliberately is not this type's job.
final class KildHTTPClientTests: XCTestCase {
    private var client: KildHTTPClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = KildHTTPClient(urlSession: URLSession(configuration: config))
    }

    // MARK: - Routes

    func testKildsReadsTheCheapListing() async throws {
        StubURLProtocol.respond(status: 200, json: "[]")
        _ = try await client.kilds()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/kilds")
    }

    /// The split is the point: a caller asking for identity must not trigger a git
    /// subprocess per kild. Two routes, two methods, no collapsing.
    func testStatusIsASeparateRouteFromTheCheapListing() async throws {
        StubURLProtocol.respond(status: 200, json: "[]")
        _ = try await client.kildsStatus()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/kilds/status")
    }

    func testArchiveReadsItsOwnRoute() async throws {
        StubURLProtocol.respond(status: 200, json: "[]")
        _ = try await client.archive()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/kilds/archive")
    }

    func testMessagesPagesOnSeqNotTimestamp() async throws {
        StubURLProtocol.respond(status: 200, json: "[]")
        _ = try await client.messages(in: "k-1", since: 412)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/kilds/k-1/messages")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "since=412")
    }

    func testMessagesWithoutACursorSendsNoQuery() async throws {
        StubURLProtocol.respond(status: 200, json: "[]")
        _ = try await client.messages(in: "k-1", since: nil)
        XCTAssertNil(StubURLProtocol.lastRequest?.url?.query)
    }

    /// An orphan kild is addressed by worktree name — arbitrary text read off disk, and
    /// `kild/*` branch names routinely contain slashes.
    ///
    /// The slash must be encoded, not passed through: `fix/some thing` is ONE identifier,
    /// and letting it split the path would address `/api/kilds/fix/some thing/messages`,
    /// which is a different resource than the caller asked for.
    func testIdentifiersAreEncodedAsASingleSegment() async throws {
        StubURLProtocol.respond(status: 200, json: "[]")
        _ = try await client.messages(in: "fix/some thing", since: nil)
        XCTAssertEqual(
            StubURLProtocol.lastRequest?.url?.absoluteString,
            "http://127.0.0.1:4517/api/kilds/fix%2Fsome%20thing/messages")
    }

    /// Encoding must happen exactly once. Encoding an already-encoded segment turns `%20`
    /// into `%2520`, which the engine reads as a literal "%20" in the name.
    func testIdentifiersAreNotDoubleEncoded() async throws {
        StubURLProtocol.respond(status: 200, json: "[]")
        _ = try await client.messages(in: "a b", since: nil)
        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url?.absoluteString)
        XCTAssertTrue(url.contains("a%20b"))
        XCTAssertFalse(url.contains("%2520"))
    }

    // MARK: - Sending

    /// `from` is absent by design — the engine attributes it from the credential. A client
    /// that could name its own sender could name anyone.
    func testSendCarriesRecipientsAndTextButNeverASender() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"ok":true}"#)
        try await client.send(to: ["coder"], text: "rebase first", in: "k-1")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/kilds/k-1/messages")

        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["to"] as? [String], ["coder"])
        XCTAssertEqual(json["text"] as? String, "rebase first")
        XCTAssertNil(json["from"], "the sender is the engine's to decide, not ours")
    }

    /// Without this header the engine records the message unattributed, which reads as the
    /// operator's own voice — an agent's opinion becomes an instruction from the human.
    func testTheCredentialIsSentWhenHeld() async throws {
        var authed = client!
        authed.token = "kat_7f3a"
        StubURLProtocol.respond(status: 200, json: #"{"ok":true}"#)
        try await authed.send(to: ["coder"], text: "hi", in: "k-1")
        XCTAssertEqual(
            StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer kat_7f3a")
    }

    func testNoAuthorizationHeaderWhenThereIsNoToken() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"ok":true}"#)
        try await client.send(to: ["coder"], text: "hi", in: "k-1")
        XCTAssertNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - The land split

    /// Dry run and execute are different verbs on one route. The UI honours that split, so
    /// the client must not quietly turn a report into an action.
    func testDryRunIsAGetAndTouchesNothing() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"ok":true,"ahead":3,"behind":0}"#)
        let report = try await client.landDryRun("k-1")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/kilds/k-1/land")
        XCTAssertEqual(report.ahead, 3)
    }

    func testLandingIsAPostToTheSameRoute() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"ok":true,"commits":3,"files":4}"#)
        let report = try await client.land("k-1")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/kilds/k-1/land")
        XCTAssertEqual(report.commits, 3)
    }

    // MARK: - Disposal

    func testDeleteUsesTheDisposalVerb() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"ok":true}"#)
        try await client.delete("k-1")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/kilds/k-1")
    }

    func testStoppingOneAgentDoesNotHaltTheKild() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"ok":true}"#)
        try await client.stopAgent("reviewer", in: "k-1")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(
            StubURLProtocol.lastRequest?.url?.path, "/api/kilds/k-1/agents/reviewer")
    }

    // MARK: - Refusals

    /// The engine explains its refusals in prose — "3 commits not reachable from base" is
    /// the whole answer. Flattening that to a status code throws away the only useful part.
    func testTheEnginesOwnRefusalTextSurvives() async {
        StubURLProtocol.respond(
            status: 409, json: #"{"error":"refusing: 3 commits not reachable from base"}"#)
        do {
            try await client.delete("k-1")
            XCTFail("a refused delete must throw")
        } catch {
            XCTAssertEqual(
                error as? KildAPIError,
                .engine("refusing: 3 commits not reachable from base"))
        }
    }

    func testANonJSONFailureStillThrowsWithItsStatus() async {
        StubURLProtocol.respond(status: 500, json: "boom")
        do {
            _ = try await client.kilds()
            XCTFail("a 500 must throw")
        } catch {
            XCTAssertEqual(error as? KildAPIError, .http(500))
        }
    }

    /// A wire change should fail here, loudly, rather than surface as an empty sidebar.
    func testAnUnreadableResponseIsADecodingFailureNotAnEmptyResult() async {
        StubURLProtocol.respond(status: 200, json: #"{"unexpected":"shape"}"#)
        do {
            _ = try await client.kilds()
            XCTFail("an undecodable body must throw")
        } catch {
            guard case .decoding = error as? KildAPIError else {
                return XCTFail("expected a decoding failure, got \(error)")
            }
        }
    }

    /// A write whose body helm ignores must still fail on refusal — discarding the response
    /// is not the same as not checking it.
    func testAWriteWithADiscardedBodyStillThrowsOnRefusal() async {
        StubURLProtocol.respond(status: 403, json: #"{"error":"seat required"}"#)
        do {
            try await client.stop("k-1")
            XCTFail("a refused stop must throw")
        } catch {
            XCTAssertEqual(error as? KildAPIError, .engine("seat required"))
        }
    }
}
