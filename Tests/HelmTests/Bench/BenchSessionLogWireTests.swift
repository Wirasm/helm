import Foundation
import HelmWire
import XCTest

/// Pocket's transcript read (#625) against `daemon/fixtures/session-log.json`, which the daemon
/// gate holds to `bench_wire::SessionLogArgs` and `SessionLog`.
final class BenchSessionLogWireTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/fixtures/session-log.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func plain(_ value: Any) throws -> NSObject {
        try JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: value)) as! NSObject
    }

    func testTheLogRequestAndAnswerAreSpelledAsTheDaemonSpellsThem() throws {
        let samples = try fixture()
        let request = BenchSessionLogRequest(id: "pocket-1", session: "c-7e2d", page: .after(0))
        XCTAssertEqual(
            try plain(JSONSerialization.jsonObject(with: JSONEncoder().encode(request))),
            try plain(XCTUnwrap(samples["request"])))

        let reply = try JSONDecoder().decode(
            BenchSessionLog.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(samples["reply"])))
        XCTAssertEqual(reply.total, 6)
        XCTAssertEqual(
            reply.entries,
            [
                BenchLogEntry(index: 1, atMs: 1_791_028_800_000, kind: .user, text: "run the gate"),
                BenchLogEntry(
                    index: 2, atMs: 1_791_028_830_000, kind: .tool, tool: "Bash",
                    text: "just check"),
                BenchLogEntry(
                    index: 3, atMs: 1_791_028_845_000, kind: .error, tool: "Bash",
                    text: "exit 1: daemon FAIL"),
                BenchLogEntry(
                    index: 4, atMs: 1_791_028_860_000, kind: .agent,
                    text: "The gate is **green**.\n\n- lint PASS\n- swift PASS"),
                BenchLogEntry(
                    index: 5, atMs: 1_791_028_900_000, kind: .user,
                    text: "You have mail from lead: /m/1.md", from: "bench"),
            ])
    }
}
