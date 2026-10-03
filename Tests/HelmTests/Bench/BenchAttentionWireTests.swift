import Foundation
import HelmWire
import XCTest

/// Attention on benchd's answers (M1, #357), against the daemon's own samples, which the daemon
/// gate holds to `bench_wire::LiveSessions` and `SessionList`: the decoder the status bar, the
/// Sessions drawer and the workspace tabs draw from.
final class BenchAttentionWireTests: XCTestCase {
    private func sample(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/fixtures/\(name)")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        try JSONDecoder().decode(
            type, from: JSONSerialization.data(withJSONObject: XCTUnwrap(value)))
    }

    func testASessionSaysItsTurnEndedAndItMailedTheOperator() throws {
        let reply = try decode(BenchLiveSessions.self, sample("session-list.json")["attention"])
        let entry = try XCTUnwrap(reply.sessions.first { $0.session == "s6" })
        XCTAssertEqual(
            entry.done,
            BenchDone(
                since: Date(timeIntervalSince1970: 1_790_540_812), to: "orchestrator", seen: false))
        XCTAssertEqual(
            entry.operatorMail,
            BenchOperatorMail(
                unread: 2, since: Date(timeIntervalSince1970: 1_790_540_790),
                subject: "reviewer: blocked"))
        let presence = try decode(BenchLiveSessions.self, sample("session-list.json")["reply"])
        XCTAssertTrue(
            presence.sessions.allSatisfy { $0.done == nil && $0.operatorMail == nil },
            "absent is nil")
    }

    func testARowSaysItsTurnEndedAndItMailedTheOperator() throws {
        let list = try decode(BenchSessionList.self, sample("session-rows.json")["list"])
        let done = list.rows.compactMap(\.done)
        XCTAssertEqual(Set(done.map(\.to)), ["orchestrator", "operator"])
        XCTAssertEqual(Set(done.map(\.seen)), [true, false])
        XCTAssertEqual(
            Set(list.rows.compactMap(\.spawner)), [.operator, .agent(handle: "orchestrator")])
        XCTAssertTrue(list.rows.contains { $0.spawner == nil }, "unknown is nil")
        XCTAssertThrowsError(
            try decode(BenchSpawner.self, ["kind": "robot"]), "a kind this build does not know")
        let subjects = list.rows.compactMap(\.operatorMail).map { $0.subject ?? "" }
        XCTAssertEqual(subjects.sorted(), ["", "reviewer: blocked"])
        XCTAssertTrue(
            list.rows.contains { $0.done == nil && $0.operatorMail == nil }, "null is nil")
    }
}
