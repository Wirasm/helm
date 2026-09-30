import HelmWire
import XCTest

@testable import Helm

/// The per-workspace rollup: one workspace's mark from what the agents in its panes report.
///
/// Pure, so every acceptance rule on #36 is checkable without a window, a pty or a live agent.
/// Which pane an agent is in is benchd's to say (its report is for the session the pane shows),
/// so there is no attribution rule left here to test.
final class BoardRollupTests: XCTestCase {

    private func report(_ activity: String) -> BenchLiveSessions.Report {
        BenchLiveSessions.Report(activity: activity)
    }

    // MARK: - The mark

    func testLitWhenAnyAgentIsNotWorking() {
        XCTAssertEqual(
            BoardModel.presence(of: [report("busy"), report("idle")]), .notWorking,
            "the mixed case is ordinary, not an edge — one stopped agent is the whole signal")
    }

    func testWaitingLightsTheSameAsIdle() {
        XCTAssertEqual(BoardModel.presence(of: [report("waiting")]), .notWorking)
    }

    func testWorkingWhenEveryAgentIsWorking() {
        XCTAssertEqual(BoardModel.presence(of: [report("busy"), report("shell")]), .working)
    }

    // MARK: - Absence

    func testNoPresenceWhenNothingReports() {
        XCTAssertNil(
            BoardModel.presence(of: []), "plain shells read as unmarked, never as idle")
    }

    // MARK: - An activity the board does not know

    func testAnUnknownActivityContributesNothing() {
        XCTAssertNil(
            BoardModel.presence(of: [report("pondering")]),
            "a word this build has never heard renders nothing rather than defaulting to idle")
    }

    func testAnUnknownActivityDoesNotSuppressASiblingsMark() {
        XCTAssertEqual(
            BoardModel.presence(of: [report("pondering"), report("idle")]), .notWorking)
        XCTAssertEqual(
            BoardModel.presence(of: [report("pondering"), report("busy")]), .working,
            "the unknown report abstains — it does not vote either way")
    }
}
