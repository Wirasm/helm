import XCTest

@testable import Helm

/// Tab command-activity state. Split out of `TerminalCapabilitiesTests` with the type.
final class TerminalActivityTests: XCTestCase {

    func testProgressStatesMapFromOSC94() {
        var activity = TerminalActivity()

        activity.reportProgress(state: .set, percent: 42)
        XCTAssertEqual(activity.progress, .percent(42))

        activity.reportProgress(state: .indeterminate, percent: nil)
        XCTAssertEqual(activity.progress, .indeterminate)

        activity.reportProgress(state: .error, percent: nil)
        XCTAssertEqual(activity.progress, .error)

        activity.reportProgress(state: .pause, percent: 80)
        XCTAssertEqual(activity.progress, .paused(80))

        activity.reportProgress(state: .remove, percent: nil)
        XCTAssertNil(activity.progress)
    }

    func testProgressPercentIsClampedAndDefaultsToZero() {
        var activity = TerminalActivity()
        activity.reportProgress(state: .set, percent: 150)
        XCTAssertEqual(activity.progress, .percent(100))
        activity.reportProgress(state: .set, percent: nil)
        XCTAssertEqual(activity.progress, .percent(0))
    }

    func testFreshProgressSupersedesStaleOutcomeButRemoveDoesNot() {
        var activity = TerminalActivity()
        activity.finishCommand(exitCode: 1, durationNanos: 5, isVisible: false)
        XCTAssertNotNil(activity.outcome)

        // A remove (a finishing command withdrawing its bar) must not eat
        // the mark…
        activity.reportProgress(state: .remove, percent: nil)
        XCTAssertNotNil(activity.outcome)

        // …but a new command starting to report progress must.
        activity.reportProgress(state: .indeterminate, percent: nil)
        XCTAssertNil(activity.outcome)
    }

    // MARK: - TerminalActivity: command finished

    func testFinishOnInactiveTabMarksByExitCode() {
        var activity = TerminalActivity()

        activity.finishCommand(exitCode: 0, durationNanos: 1_500_000_000, isVisible: false)
        XCTAssertEqual(activity.outcome, .success(durationNanos: 1_500_000_000))

        activity.finishCommand(exitCode: 2, durationNanos: 3_000_000_000, isVisible: false)
        XCTAssertEqual(activity.outcome, .failure(exitCode: 2, durationNanos: 3_000_000_000))
    }

    func testFinishOnSelectedTabLeavesNoChrome() {
        var activity = TerminalActivity()
        activity.reportProgress(state: .set, percent: 90)

        activity.finishCommand(exitCode: 1, durationNanos: 10, isVisible: true)

        XCTAssertNil(activity.outcome, "the user watched the active tab — no mark")
        XCTAssertNil(activity.progress, "finish always retires the progress hint")
    }

    func testUnknownExitCodeMarksNothing() {
        var activity = TerminalActivity()
        activity.finishCommand(exitCode: nil, durationNanos: 10, isVisible: false)
        XCTAssertNil(activity.outcome, "no exit code, nothing truthful to show")
    }

    func testAcknowledgeClearsOutcomeButKeepsLiveProgress() {
        var activity = TerminalActivity()
        activity.finishCommand(exitCode: 0, durationNanos: 10, isVisible: false)
        activity.reportProgress(state: .set, percent: 10)
        activity.finishCommand(exitCode: 1, durationNanos: 20, isVisible: false)
        activity.reportProgress(state: .set, percent: 55)

        // outcome was superseded by fresh progress above; rebuild the combo:
        // live progress + unacknowledged mark can't coexist by construction,
        // so verify each side of acknowledge independently.
        activity.acknowledge()
        XCTAssertEqual(activity.progress, .percent(55), "progress is not attention")

        activity.finishCommand(exitCode: 1, durationNanos: 20, isVisible: false)
        activity.acknowledge()
        XCTAssertNil(activity.outcome)
    }

    // MARK: - Duration formatting

    func testDurationFormatsAcrossScales() {
        XCTAssertEqual(TerminalActivity.formatDuration(nanos: 312_000_000), "312ms")
        XCTAssertEqual(TerminalActivity.formatDuration(nanos: 3_200_000_000), "3.2s")
        XCTAssertEqual(TerminalActivity.formatDuration(nanos: 192_000_000_000), "3m 12s")
        XCTAssertEqual(TerminalActivity.formatDuration(nanos: 4_320_000_000_000), "1h 12m")
    }

    func testOutcomeTooltipsCarryDurationAndExitCode() {
        XCTAssertEqual(
            TerminalActivity.Outcome.success(durationNanos: 3_200_000_000).tooltip,
            "Command finished in 3.2s"
        )
        XCTAssertEqual(
            TerminalActivity.Outcome.failure(exitCode: 127, durationNanos: 500_000_000).tooltip,
            "Command failed (exit 127) after 500ms"
        )
    }

    // MARK: - Notification gating
}
