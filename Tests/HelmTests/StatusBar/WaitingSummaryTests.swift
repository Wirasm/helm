import HelmWire
import XCTest

@testable import Helm

/// The status bar's count of agents waiting on the operator (M1, #357).
final class WaitingSummaryTests: XCTestCase {
    func testNobodyWaitingShowsNothing() {
        XCTAssertNil(WaitingSummary([BenchLiveSessions.Waiting]()))
    }

    func testTheCountAndTheLongestWaitAreWhatItSays() throws {
        let waits = [
            BenchLiveSessions.Waiting(
                waitingFor: "question", since: Date(timeIntervalSince1970: 200), source: "hook"),
            BenchLiveSessions.Waiting(
                waitingFor: "permission prompt", since: Date(timeIntervalSince1970: 100),
                source: "screen"),
        ]
        let summary = try XCTUnwrap(WaitingSummary(waits))
        XCTAssertEqual(summary.label, "2 waiting")
        XCTAssertTrue(summary.help.contains("The longest: permission prompt"), summary.help)
    }
}
