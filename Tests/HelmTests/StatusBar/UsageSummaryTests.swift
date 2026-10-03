import HelmWire
import XCTest

@testable import Helm

/// The status bar's plan limits (#143): which figure each harness shows, and the two rules that
/// keep an old one from looking current.
final class UsageSummaryTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-09-27 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_790_510_400)

    private func window(
        _ minutes: Int, _ used: Double, resetsIn: TimeInterval?, ago: TimeInterval = 60
    )
        -> BenchUsage.Window
    {
        .init(
            minutes: minutes, usedPercent: used, resetsAt: resetsIn.map { now + $0 },
            at: now - ago)
    }

    func testNothingReportedShowsNothing() {
        XCTAssertNil(UsageSummary([], now: now, calendar: utc))
    }

    func testEachHarnessShowsItsFullestWindowAndWhenItResets() throws {
        let usage = [
            BenchUsage(
                harness: "claude",
                windows: [
                    window(300, 62.4, resetsIn: 2 * 3600), window(10080, 30, resetsIn: 5 * 86400),
                ]),
            BenchUsage(harness: "codex", windows: [window(10080, 30, resetsIn: nil)]),
        ]
        let summary = try XCTUnwrap(UsageSummary(usage, now: now, calendar: utc))
        XCTAssertEqual(
            summary.parts.map(\.label), ["Claude 62% · resets 14:00", "codex 30%"])
        XCTAssertFalse(summary.nearLimit)
        XCTAssertTrue(
            summary.help.contains("Claude 7d 30% · resets Fri 12:00"), summary.help)
    }

    /// A second Claude login is a plan of its own: its own part, named by its config dir, and its
    /// own lines in the help.
    func testASecondClaudeLoginShowsApartByItsConfigDir() throws {
        let usage = [
            BenchUsage(harness: "claude", windows: [window(300, 62, resetsIn: 2 * 3600)]),
            BenchUsage(
                harness: "claude", account: "/Users/op/.claude-b",
                windows: [window(300, 12, resetsIn: 3 * 3600)]),
        ]
        let summary = try XCTUnwrap(UsageSummary(usage, now: now, calendar: utc))
        XCTAssertEqual(
            summary.parts.map(\.label),
            ["Claude 62% · resets 14:00", "Claude .claude-b 12% · resets 15:00"])
        XCTAssertTrue(
            summary.help.contains("Claude .claude-b 5h 12% · resets 15:00"), summary.help)
    }

    /// A window past its reset time says nothing true any more: the next one shows, and a harness
    /// with none left is absent.
    func testAWindowThatHasResetIsDropped() throws {
        let usage = [
            BenchUsage(
                harness: "claude",
                windows: [window(300, 95, resetsIn: -60), window(10080, 40, resetsIn: 86400)]),
            BenchUsage(harness: "codex", windows: [window(10080, 80, resetsIn: -1)]),
        ]
        let summary = try XCTUnwrap(UsageSummary(usage, now: now, calendar: utc))
        XCTAssertEqual(summary.parts.map(\.label), ["Claude 40% · resets Mon 12:00"])
        XCTAssertFalse(summary.nearLimit, "the 95% was the reset window's")
    }

    /// Older than 15 minutes is faint and dated; it never fills the capsule as near the limit.
    func testAFigureOlderThanFifteenMinutesIsStale() throws {
        let usage = [
            BenchUsage(
                harness: "codex",
                windows: [window(10080, 95, resetsIn: 86400, ago: 16 * 60)])
        ]
        let summary = try XCTUnwrap(UsageSummary(usage, now: now, calendar: utc))
        XCTAssertEqual(summary.parts.map(\.stale), [true])
        XCTAssertFalse(summary.nearLimit)
        XCTAssertTrue(summary.help.contains("as of 11:44"), summary.help)

        let fresh = try XCTUnwrap(
            UsageSummary(
                [
                    BenchUsage(
                        harness: "codex",
                        windows: [window(10080, 95, resetsIn: 86400, ago: 14 * 60)])
                ],
                now: now, calendar: utc))
        XCTAssertEqual(fresh.parts.map(\.stale), [false])
        XCTAssertTrue(fresh.nearLimit, "a current 95% is near the limit")
    }
}
