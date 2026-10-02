import Foundation
import HelmWire
import PocketKit
import XCTest

/// Pocket's model against a benchd stand-in over TCP (`FakeBenchd`), the only way Pocket reaches
/// one: the workspaces come from the follower, the sessions from `sessions/all`, and a key goes
/// out as `screen/send keys: true`. Here rather than in PocketKitTests because the fake is here.
@MainActor
final class PocketModelTests: XCTestCase {
    /// One `sessions/all` row: a waiting agent with a mailbox, on the bench as session s7.
    nonisolated private static func row() -> [String: Any] {
        [
            "harness": "claude", "id": "9496c9f4-8105", "cwd": "/w/helm",
            "model": "claude-opus-5-5",
            "state": [
                "kind": "running", "activity": ["kind": "waiting", "waiting_for": "permission"],
            ],
            "open": ["kind": "bench_attach", "session": "s7"], "updated_at_ms": 1,
            "mail": ["handle": "daemon-7915", "unread": 0, "wakeable": true],
        ]
    }

    func testItFollowsListsAndTypesKeysOverTCP() async throws {
        let server = try FakeBenchd(
            document: BenchFixture.document(
                "/w/helm", BenchFixture.bench([BenchFixture.terminal()]), seq: 1),
            tcp: true)
        defer { server.stop() }
        server.answer = { request in
            let id = request["id"] ?? ""
            switch request["verb"] as? String {
            case "sessions/all": return ["id": id, "status": "ok", "data": ["rows": [Self.row()]]]
            case "screen/send"
            where (request["args"] as? [String: Any])?["target"] as? String == "s7":
                return ["id": id, "status": "ok", "data": ["session": "s7", "bracketed": false]]
            default: return ["id": id, "status": "refused", "reason": "no session s9"]
            }
        }
        let model = PocketModel()
        model.connect(server.endpoint.description)
        // Yielding, not pumping the runloop: this test runs on the main queue, which delivers
        // the follower's document only once the test lets go of it.
        for _ in 0..<150 where model.workspaces.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.workspaces, ["/w/helm"], "\(model.state)")

        await model.refreshSessions()
        XCTAssertEqual(model.sessions["/w/helm"]?.map(\.title), ["daemon-7915"])

        let refusal = await model.send(PocketKey.escape.input, to: "s7")
        XCTAssertNil(refusal)
        let sent = try XCTUnwrap(server.requests.last { $0["verb"] as? String == "screen/send" })
        let args = try XCTUnwrap(sent["args"] as? [String: Any])
        XCTAssertEqual(args["text"] as? String, "\u{1b}")
        XCTAssertEqual(args["keys"] as? Bool, true)
        XCTAssertNil(args["enter"], "a key is not followed by Return")

        // A refused send comes back to the caller in benchd's words.
        let refused = await model.send(.message("status?"), to: "s9")
        XCTAssertEqual(refused?.description, "no session s9")

        // A workspace benchd does not answer for keeps the rows it had, and says why.
        let answer = server.answer
        server.answer = { request in
            guard request["verb"] as? String == "sessions/all" else { return answer(request) }
            return ["id": request["id"] ?? "", "status": "refused", "reason": "busy"]
        }
        await model.refreshSessions()
        XCTAssertEqual(model.sessions["/w/helm"]?.map(\.title), ["daemon-7915"])
        XCTAssertEqual(model.failure, "busy")
        server.answer = answer

        // benchd's refusal reaches the screen in its own words.
        switch await model.screen("s9") {
        case .success: XCTFail("a refused screen/get answered")
        case let .failure(why): XCTAssertEqual(why.description, "no session s9")
        }
    }

    /// Pocket reaches benchd over TCP only: anything else is refused by name, and nothing is
    /// followed.
    func testAnythingButTCPIsRefusedByName() {
        let model = PocketModel()
        model.connect("/Users/op/.bench/benchd.sock")
        XCTAssertEqual(
            model.state, .disconnected("/Users/op/.bench/benchd.sock is not tcp://<host>:<port>"))
        XCTAssertNil(model.endpoint)
    }
}
