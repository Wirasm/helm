import Foundation
import HelmWire
import XCTest

/// The plan limits in benchd's `sessions` answer (#143), against the daemon's own sample in
/// `daemon/fixtures/session-list.json`, which the daemon gate holds to `bench_wire::LiveSessions`.
/// Beside `BenchWireConformanceTests` rather than in it, which is at its size limit.
final class BenchUsageWireTests: XCTestCase {
    func testTheSessionListSampleCarriesEachHarnesssLimits() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/fixtures/session-list.json")
        let samples =
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let reply = try JSONDecoder().decode(
            BenchLiveSessions.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(samples["reply"])))
        XCTAssertEqual(
            reply.usage,
            [
                BenchUsage(
                    harness: "claude",
                    windows: [
                        .init(
                            minutes: 300, usedPercent: 62,
                            resetsAt: Date(timeIntervalSince1970: 1_790_553_600),
                            at: Date(timeIntervalSince1970: 1_790_540_800)),
                        .init(
                            minutes: 10080, usedPercent: 30.5,
                            resetsAt: Date(timeIntervalSince1970: 1_791_043_200),
                            at: Date(timeIntervalSince1970: 1_790_540_800)),
                    ]),
                BenchUsage(
                    harness: "claude", account: "/Users/op/.claude-b",
                    windows: [
                        .init(
                            minutes: 300, usedPercent: 12,
                            resetsAt: Date(timeIntervalSince1970: 1_790_550_000),
                            at: Date(timeIntervalSince1970: 1_790_540_700)),
                        .init(
                            minutes: 10080, usedPercent: 71,
                            resetsAt: Date(timeIntervalSince1970: 1_790_600_000),
                            at: Date(timeIntervalSince1970: 1_790_540_700)),
                    ]),
                BenchUsage(
                    harness: "codex",
                    windows: [
                        .init(
                            minutes: 10080, usedPercent: 30, resetsAt: nil,
                            at: Date(timeIntervalSince1970: 1_790_534_669.555))
                    ]),
            ],
            "each harness's plan limits (#143), a second Claude login's apart, and a window with no "
                + "reset time")
    }
}
