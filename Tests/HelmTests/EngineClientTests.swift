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
        client = EngineClient(session: URLSession(configuration: config))
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
                  { "name": "worker", "agent": "implementor", "model": "sol-4" },
                  { "name": "reviewer" }
                ],
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
        XCTAssertEqual(room.participants[0].model, "sol-4")
        XCTAssertNil(room.participants[1].model)

        // Only unresolved decisions count as open.
        XCTAssertEqual(room.openDecisions.map(\.key), ["api-shape"])

        // system/implicit drive the muted rendering; ts converts from epoch millis.
        XCTAssertEqual(room.log.map(\.isMuted), [false, true, true])
        XCTAssertEqual(room.log[0].date.timeIntervalSince1970, 1_753_300_000, accuracy: 0.001)

        // lastPost skips system notices but keeps implicit agent replies.
        XCTAssertEqual(room.lastPost?.id, "m3")
    }

    func testHealthDecoding() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"ok":true,"bootId":"abcd1234efgh"}"#)
        let health = try await client.health()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.bootId, "abcd1234efgh")
    }
}

// MARK: - URLProtocol stub

/// Serves one canned response and captures the request (including its body, which
/// URLSession delivers as a stream, not `httpBody`). XCTest runs methods serially,
/// so lock-guarded statics are sufficient.
final class StubURLProtocol: URLProtocol {
    private struct Canned {
        let status: Int
        let body: Data
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var canned: Canned?
    private nonisolated(unsafe) static var _lastRequest: URLRequest?
    private nonisolated(unsafe) static var _lastRequestBody: Data?

    static func respond(status: Int, json: String) {
        lock.lock()
        defer { lock.unlock() }
        canned = Canned(status: status, body: Data(json.utf8))
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        canned = nil
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
        let canned = Self.canned
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
