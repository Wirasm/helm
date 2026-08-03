import XCTest

@testable import Helm

/// The store behind "stop showing me this" — checked as a value, because the arithmetic it
/// feeds is what stops a dismissed run reappearing as a number one line further down.
final class ArchonDismissalsTests: XCTestCase {
    private let workspace = "/tmp/project"

    func testARunIsDismissedInOneWorkspaceOnly() {
        var dismissals = ArchonDismissals()
        dismissals.dismiss([ArchonDismissal(id: "a", status: "completed")], in: workspace)

        XCTAssertTrue(dismissals.contains("a", in: workspace))
        XCTAssertFalse(dismissals.contains("a", in: "/tmp/other"))
        XCTAssertEqual(dismissals.count(of: "completed", in: workspace), 1)
        XCTAssertEqual(dismissals.count(of: "failed", in: workspace), 0)
    }

    /// The status is stored so the rail can subtract a dismissal from the right bucket. A run
    /// dismissed while `running` and dismissed again once `completed` has to count once, under
    /// the status it is in NOW — otherwise the old bucket goes negative and the new one never
    /// clears.
    func testDismissingTheSameRunTwiceMovesItRatherThanCountingItTwice() {
        var dismissals = ArchonDismissals()
        dismissals.dismiss([ArchonDismissal(id: "a", status: "running")], in: workspace)
        dismissals.dismiss([ArchonDismissal(id: "a", status: "completed")], in: workspace)

        XCTAssertEqual(dismissals.total(in: workspace), 1)
        XCTAssertEqual(dismissals.count(of: "running", in: workspace), 0)
        XCTAssertEqual(dismissals.count(of: "completed", in: workspace), 1)
    }

    /// **Deliberately forgettable, and bounded for it.** A year of runs cannot be allowed to
    /// grow this blob without limit, so the oldest dismissals fall off the end. A run that
    /// reappears after that is the documented property, not a bug — which is exactly why none
    /// of this is called deletion.
    func testTheOldestDismissalsFallOffTheEnd() {
        var dismissals = ArchonDismissals()
        let overflow = ArchonDismissals.capacity + 10
        dismissals.dismiss(
            (0..<overflow).map { ArchonDismissal(id: "run-\($0)", status: "completed") },
            in: workspace)

        XCTAssertEqual(dismissals.total(in: workspace), ArchonDismissals.capacity)
        XCTAssertFalse(dismissals.contains("run-0", in: workspace), "the oldest is what is lost")
        XCTAssertTrue(dismissals.contains("run-\(overflow - 1)", in: workspace))
    }

    func testDismissalsRoundTripThroughDefaults() throws {
        let defaults = try isolatedDefaults("archon-dismissals-round-trip")
        var dismissals = ArchonDismissals()
        dismissals.dismiss([ArchonDismissal(id: "a", status: "failed")], in: workspace)
        dismissals.save(to: defaults)

        let loaded = ArchonDismissals.load(from: defaults)

        XCTAssertEqual(loaded, dismissals)
        XCTAssertEqual(loaded.count(of: "failed", in: workspace), 1)
    }

    /// A blob written by some other build, or by hand, must cost the operator their dismissals
    /// and nothing else — this is a view filter, and refusing to launch over one would be a
    /// wildly disproportionate answer.
    func testAnUnreadableBlobIsDroppedRatherThanThrownOn() throws {
        let defaults = try isolatedDefaults("archon-dismissals-corrupt")
        defaults.set("{not json", forKey: ArchonDismissals.key)

        XCTAssertEqual(ArchonDismissals.load(from: defaults), ArchonDismissals())
    }

    func testRestoringClearsOneWorkspaceAndLeavesTheOthers() {
        var dismissals = ArchonDismissals()
        dismissals.dismiss([ArchonDismissal(id: "a", status: "completed")], in: workspace)
        dismissals.dismiss([ArchonDismissal(id: "b", status: "completed")], in: "/tmp/other")

        dismissals.restoreAll(in: workspace)

        XCTAssertEqual(dismissals.total(in: workspace), 0)
        XCTAssertEqual(dismissals.total(in: "/tmp/other"), 1)
    }
}
