import Foundation
import XCTest

@testable import Helm

/// EngineClient contract tests against the kild engine's REST shapes, using a
/// URLProtocol stub — no engine, no network. Shapes mirror the engine source
/// (`server.ts` / `room-types.ts`): posts reply `{ok, message}` on 200 and
/// `{error}` with 4xx on rejection; `/api/rooms/live` serves `LiveRoomStatus[]`.
final class EngineClientTests: XCTestCase {
    private var client: EngineClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = EngineClient(urlSession: URLSession(configuration: config))
    }

    // MARK: steering POST

    func testPostEncodesHumanSteeringRequest() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"ok":true,"message":"delivered to @worker"}"#)

        let confirmation = try await client.post(inRoom: "room-1", text: "@worker ship it")

        XCTAssertEqual(confirmation, "delivered to @worker")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/rooms/room-1/post")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        // Exactly {text}: no `from`/`sessionId` — actor identity is engine-derived,
        // and omitting both attributes the post to the human.
        XCTAssertEqual(payload["text"] as? String, "@worker ship it")
        XCTAssertEqual(payload.count, 1)
    }

    func testPostSurfacesEngineRejectionText() async {
        // Verbatim engine rejection shape (room-manager's unknown-recipient message).
        StubURLProtocol.respond(
            status: 409,
            json: #"{"error":"no such participant: @planner (in the room: @worker)"}"#
        )

        do {
            try await client.post(inRoom: "room-1", text: "@planner hello")
            XCTFail("expected the engine rejection to throw")
        } catch let failure as EngineClient.Failure {
            XCTAssertEqual(
                failure,
                .engine("no such participant: @planner (in the room: @worker)")
            )
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testPostWithoutReadableErrorBodyThrowsBadResponse() async {
        StubURLProtocol.respond(status: 500, json: "boom")

        do {
            try await client.post(inRoom: "room-1", text: "hi")
            XCTFail("expected a failure")
        } catch let failure as EngineClient.Failure {
            XCTAssertEqual(failure, .badResponse(500))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: live-rooms decoding

    func testLiveRoomsDecodingAndDerivedViews() async throws {
        StubURLProtocol.respond(
            status: 200,
            json: """
            [
              {
                "id": "room-1",
                "name": "fix-2247",
                "state": "running",
                "participants": [
                  { "name": "worker", "persona": "implementor", "model": "sol-4" },
                  { "name": "reviewer" }
                ],
                "worktree": "fix-2247",
                "git": {
                  "path": "/Users/dev/.config/kild/worktrees/fix-2247",
                  "branch": "kild/fix-2247", "base": "main", "ahead": 1, "behind": 0,
                  "dirty": false, "uncommittedFiles": 0, "changedFiles": ["a.swift"],
                  "conflictsWithBase": false
                },
                "log": [
                  { "id": "m1", "roomId": "room-1", "from": "human", "to": ["worker"],
                    "text": "kick off", "ts": 1753300000000 },
                  { "id": "m2", "roomId": "room-1", "from": "worker", "to": [],
                    "text": "reviewer joined", "ts": 1753300001000, "system": true },
                  { "id": "m3", "roomId": "room-1", "from": "worker", "to": ["human"],
                    "text": "needs-decision[api-shape]: REST or WS?", "ts": 1753300002000,
                    "implicit": true }
                ],
                "decisions": [
                  { "key": "api-shape", "summary": "REST or WS?", "openedBy": "worker",
                    "openedAt": 1753300002000 },
                  { "key": "done-before", "summary": "old one", "openedBy": "worker",
                    "openedAt": 1753200000000, "resolvedAt": 1753210000000,
                    "resolvedBy": "human" }
                ]
              }
            ]
            """
        )

        let rooms = try await client.liveRooms()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/rooms/live")

        let room = try XCTUnwrap(rooms.first)
        XCTAssertEqual(room.id, "room-1")
        XCTAssertEqual(room.participants.map(\.name), ["worker", "reviewer"])
        // The wire says `persona` (vocabulary wave — no `agent` alias).
        XCTAssertEqual(room.participants[0].persona, "implementor")
        XCTAssertEqual(room.participants[0].model, "sol-4")
        XCTAssertNil(room.participants[1].persona)
        XCTAssertNil(room.participants[1].model)

        // Only unresolved decisions count as open.
        XCTAssertEqual(room.openDecisions.map(\.key), ["api-shape"])

        // system/implicit drive the muted rendering; ts converts from epoch millis.
        XCTAssertEqual(room.log.map(\.isMuted), [false, true, true])
        XCTAssertEqual(room.log[0].date.timeIntervalSince1970, 1_753_300_000, accuracy: 0.001)

        // lastPost skips system notices but keeps implicit agent replies.
        XCTAssertEqual(room.lastPost?.id, "m3")

        // Room identity: worktree name + the effective git dir (the filter key).
        XCTAssertEqual(room.worktree, "fix-2247")
        XCTAssertEqual(room.git?.path, "/Users/dev/.config/kild/worktrees/fix-2247")
    }

    // MARK: project attribution (the room→project filter key)

    func testBelongsToProjectMatchesGitPathAndWorktreeName() throws {
        func room(git: String?, worktree: String?, cwd: String? = nil) throws -> EngineClient.LiveRoom {
            let json = """
            { "id": "r", "name": "r", "participants": [], "log": []
              \(worktree.map { #", "worktree": "\#($0)""# } ?? "")
              \(cwd.map { #", "cwd": "\#($0)""# } ?? "")
              \(git.map { #", "git": {"path": "\#($0)"}"# } ?? "") }
            """
            return try JSONDecoder().decode(EngineClient.LiveRoom.self, from: Data(json.utf8))
        }

        // cwd rooms: git.path prefix-matches the project path — exact dir, child,
        // but never a sibling sharing the prefix string.
        XCTAssertTrue(try room(git: "/p/kild", worktree: nil)
            .belongsToProject(at: "/p/kild", worktreeNames: []))
        XCTAssertTrue(try room(git: "/p/kild/sub", worktree: nil)
            .belongsToProject(at: "/p/kild/", worktreeNames: []))
        XCTAssertFalse(try room(git: "/p/kild-ui", worktree: nil)
            .belongsToProject(at: "/p/kild", worktreeNames: []))

        // worktree rooms live under $KILD_HOME, not the project — they match via the
        // project's worktree names (from /api/worktrees), never the path.
        XCTAssertTrue(try room(git: "/home/.config/kild/worktrees/fix", worktree: "fix")
            .belongsToProject(at: "/p/kild", worktreeNames: ["fix"]))
        XCTAssertFalse(try room(git: "/home/.config/kild/worktrees/fix", worktree: "fix")
            .belongsToProject(at: "/p/kild", worktreeNames: ["other"]))

        // archived rooms carry no git at all — only the worktree-name test can match.
        XCTAssertTrue(try room(git: nil, worktree: "fix")
            .belongsToProject(at: "/p/kild", worktreeNames: ["fix"]))
        XCTAssertFalse(try room(git: nil, worktree: nil)
            .belongsToProject(at: "/p/kild", worktreeNames: ["fix"]))

        // archived rooms with a persisted cwd (kild #669): the cwd attributes them
        // directly — no live worktree needed; sibling-prefix paths still don't match.
        XCTAssertTrue(try room(git: nil, worktree: nil, cwd: "/p/kild")
            .belongsToProject(at: "/p/kild", worktreeNames: []))
        XCTAssertTrue(try room(git: nil, worktree: nil, cwd: "/p/kild/sub")
            .belongsToProject(at: "/p/kild", worktreeNames: []))
        XCTAssertFalse(try room(git: nil, worktree: nil, cwd: "/p/kild-ui")
            .belongsToProject(at: "/p/kild", worktreeNames: []))

        // live rooms prefer the effective git dir; cwd only steps in without git.
        XCTAssertTrue(try room(git: "/p/kild/sub", worktree: nil, cwd: "/elsewhere")
            .belongsToProject(at: "/p/kild", worktreeNames: []))
    }

    // MARK: archived display state (never "running" in the archive)

    func testArchivedDisplayStateNeverShowsRunning() throws {
        func room(state: String?) throws -> EngineClient.ArchivedRoom {
            let json = """
            { "id": "r", "name": "r", "participants": [], "log": []
              \(state.map { #", "state": "\#($0)""# } ?? "") }
            """
            return try JSONDecoder().decode(EngineClient.ArchivedRoom.self, from: Data(json.utf8))
        }

        // A snapshot frozen at "running" was interrupted by an engine restart.
        XCTAssertEqual(try room(state: "running").archivedDisplayState, "interrupted")
        XCTAssertEqual(try room(state: "closed").archivedDisplayState, "closed")
        XCTAssertEqual(try room(state: nil).archivedDisplayState, "closed")
        XCTAssertEqual(try room(state: "halted").archivedDisplayState, "halted")
    }

    // MARK: archive decoding

    func testArchivedRoomsDecodingWithResolutionsAndResumeHandles() async throws {
        // Mirror of the engine's ArchivedRoom snapshot: live shape minus git/totals,
        // decisions carrying their resolutions, participants their pi resume handles.
        StubURLProtocol.respond(
            status: 200,
            json: """
            [
              {
                "id": "room-9",
                "name": "ship-auth",
                "state": "closed",
                "worktree": "ship-auth",
                "cwd": "/Users/dev/projects/auth",
                "participants": [
                  { "name": "lead", "persona": "orchestrator", "model": "sol-4",
                    "piSessionId": "abc",
                    "piSessionFile": "/Users/dev/.pi/sessions/abc.jsonl" },
                  { "name": "scout" }
                ],
                "log": [
                  { "id": "m1", "roomId": "room-9", "from": "lead", "to": ["human"],
                    "text": "resolved[api-shape]: REST it is", "ts": 1753300005000 }
                ],
                "decisions": [
                  { "key": "api-shape", "summary": "REST or WS?", "openedBy": "lead",
                    "openedAt": 1753300002000, "resolvedAt": 1753300005000,
                    "resolvedBy": "human", "note": "REST it is" }
                ]
              }
            ]
            """
        )

        let archive = try await client.archivedRooms()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/rooms/archive")

        let room = try XCTUnwrap(archive.first)
        XCTAssertEqual(room.state, "closed")
        XCTAssertNil(room.git)
        // The persisted cwd (kild #669) — the archive's project-attribution key.
        XCTAssertEqual(room.cwd, "/Users/dev/projects/auth")
        XCTAssertTrue(room.openDecisions.isEmpty)

        let decision = try XCTUnwrap(room.decisions?.first)
        XCTAssertEqual(decision.resolvedBy, "human")
        XCTAssertEqual(decision.note, "REST it is")

        // The durable terminal-resume handle → the copyable command.
        XCTAssertEqual(
            room.participants[0].resumeCommand,
            "pi --session /Users/dev/.pi/sessions/abc.jsonl"
        )
        XCTAssertNil(room.participants[1].resumeCommand)
    }

    // MARK: worktrees (the workspace→worktree-room link)

    private static let worktreesJSON =
        #"[{"branch":"kild/fix-2247","path":"/Users/dev/.config/kild/worktrees/fix-2247","name":"fix-2247"}]"#

    func testWorktreesDecodingAndQueryEncoding() async throws {
        StubURLProtocol.respond(status: 200, json: Self.worktreesJSON)
        let trees = try await client.worktrees(project: "kild")
        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/worktrees")
        XCTAssertEqual(url.query, "project=kild")
        // Wire field `name` decodes into the unified `worktree` handle.
        XCTAssertEqual(trees.first?.worktree, "fix-2247")
        XCTAssertEqual(trees.first?.branch, "kild/fix-2247")
    }

    /// A workspace is an unregistered folder, so its worktrees are fetched under the
    /// engine's OTHER reference key. `project=<a path>` would 404 — exactly one of
    /// the two keys is sent, never both.
    func testWorktreesByPathSendsPathQueryNotProject() async throws {
        StubURLProtocol.respond(status: 200, json: Self.worktreesJSON)
        let trees = try await client.worktrees(path: "/Users/dev/kild")
        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/worktrees")
        XCTAssertEqual(url.query, "path=/Users/dev/kild")
        XCTAssertEqual(trees.first?.worktree, "fix-2247")
    }

    /// A folder that is no git repo legitimately 400s; the client surfaces the
    /// engine's text and KildStore swallows it into "no worktree names".
    func testWorktreesByPathSurfacesEngineRejection() async {
        StubURLProtocol.respond(status: 400, json: #"{"error":"not a git repository"}"#)
        do {
            _ = try await client.worktrees(path: "/tmp/plain-folder")
            XCTFail("expected the engine rejection to throw")
        } catch let failure as EngineClient.Failure {
            XCTAssertEqual(failure, .engine("not a git repository"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testHealthDecoding() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"ok":true,"bootId":"abcd1234efgh"}"#)
        let health = try await client.health()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.bootId, "abcd1234efgh")
    }
}

// MARK: - URLProtocol stub

/// Serves canned responses and captures the request (including its body, which
/// URLSession delivers as a stream, not `httpBody`). A single catch-all response is
/// enough for one-call tests; per-path responses let a multi-call flow like
/// `KildStore.load()` be driven end to end. XCTest runs methods serially, so
/// lock-guarded statics are sufficient.
final class StubURLProtocol: URLProtocol {
    private struct Canned {
        let status: Int
        let body: Data
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var canned: Canned?
    private nonisolated(unsafe) static var cannedByPath: [String: Canned] = [:]
    private nonisolated(unsafe) static var _lastRequest: URLRequest?
    private nonisolated(unsafe) static var _lastRequestBody: Data?

    static func respond(status: Int, json: String) {
        lock.lock()
        defer { lock.unlock() }
        canned = Canned(status: status, body: Data(json.utf8))
    }

    /// A response for one endpoint, taking precedence over the catch-all.
    static func respond(path: String, status: Int, json: String) {
        lock.lock()
        defer { lock.unlock() }
        cannedByPath[path] = Canned(status: status, body: Data(json.utf8))
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        canned = nil
        cannedByPath = [:]
        _lastRequest = nil
        _lastRequestBody = nil
    }

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _lastRequest
    }

    static var lastRequestBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _lastRequestBody
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }

        Self.lock.lock()
        Self._lastRequest = request
        Self._lastRequestBody = body
        let canned = request.url.flatMap { Self.cannedByPath[$0.path] } ?? Self.canned
        Self.lock.unlock()

        guard let canned else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: canned.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
