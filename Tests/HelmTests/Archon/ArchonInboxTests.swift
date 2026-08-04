import XCTest

@testable import Helm

final class ArchonInboxTests: XCTestCase {
    private let workspace = "/tmp/project"
    private let now = Date(timeIntervalSince1970: 1_785_832_000)

    func testARunIsClearedInOneWorkspaceOnly() {
        var dismissals = ArchonInboxDismissals()
        dismissals.dismiss("a", in: workspace, now: now)

        XCTAssertTrue(dismissals.contains("a", in: workspace))
        XCTAssertFalse(dismissals.contains("a", in: "/tmp/other"))
    }

    func testClearingTheSameRunTwiceMovesItRatherThanCountingItTwice() {
        var dismissals = ArchonInboxDismissals()
        dismissals.dismiss("a", in: workspace, now: now)
        dismissals.dismiss("a", in: workspace, now: now.addingTimeInterval(60))

        XCTAssertEqual(dismissals.total(in: workspace), 1)
        XCTAssertTrue(dismissals.contains("a", in: workspace))
    }

    func testTheOldestClearedRunsFallOffTheEnd() {
        var dismissals = ArchonInboxDismissals()
        let overflow = ArchonInboxDismissals.capacity + 10
        for index in 0..<overflow {
            dismissals.dismiss("run-\(index)", in: workspace, now: now)
        }

        XCTAssertEqual(dismissals.total(in: workspace), ArchonInboxDismissals.capacity)
        XCTAssertFalse(dismissals.contains("run-0", in: workspace), "the oldest is what is lost")
        XCTAssertTrue(dismissals.contains("run-\(overflow - 1)", in: workspace))
    }

    /// The age-out, and the reason `dismiss` and `prune` take `now` rather than reading the
    /// clock: this asserts a fortnight without waiting one.
    func testADismissalOlderThanTheMaximumAgeIsPruned() {
        var dismissals = ArchonInboxDismissals()
        dismissals.dismiss("stale", in: workspace, now: now)
        dismissals.dismiss("fresh", in: workspace, now: now.addingTimeInterval(60 * 60))

        dismissals.prune(
            now: now.addingTimeInterval(ArchonInboxDismissals.maximumAge + 60))

        XCTAssertFalse(dismissals.contains("stale", in: workspace))
        XCTAssertTrue(dismissals.contains("fresh", in: workspace))
    }

    func testPruningIsANoOpWhileEverythingIsFresh() {
        var dismissals = ArchonInboxDismissals()
        dismissals.dismiss("a", in: workspace, now: now)

        dismissals.prune(now: now.addingTimeInterval(60))

        XCTAssertTrue(dismissals.contains("a", in: workspace))
    }

    /// A workspace whose entries have all aged out is dropped rather than left as an empty
    /// array, so the blob does not grow one key per workspace ever opened.
    func testAWorkspaceEmptiedByPruningIsDroppedEntirely() throws {
        let defaults = try isolatedDefaults("archon-inbox-empty-workspace")
        var dismissals = ArchonInboxDismissals()
        dismissals.dismiss("a", in: workspace, now: now)

        dismissals.prune(now: now.addingTimeInterval(ArchonInboxDismissals.maximumAge + 60))
        dismissals.save(to: defaults)

        XCTAssertEqual(dismissals.total(in: workspace), 0)
        let raw = try XCTUnwrap(defaults.string(forKey: ArchonInboxDismissals.key))
        XCTAssertEqual(raw, "{}", "an emptied workspace leaves no key behind")
    }

    func testDismissalsRoundTripThroughDefaults() throws {
        let defaults = try isolatedDefaults("archon-inbox-round-trip")
        var dismissals = ArchonInboxDismissals()
        dismissals.dismiss("a", in: workspace, now: now)
        dismissals.save(to: defaults)

        let loaded = ArchonInboxDismissals.load(from: defaults)

        XCTAssertEqual(loaded, dismissals)
        XCTAssertTrue(loaded.contains("a", in: workspace))
    }

    func testAnUnreadableBlobIsDroppedRatherThanThrownOn() throws {
        let defaults = try isolatedDefaults("archon-inbox-corrupt")
        defaults.set("{not json", forKey: ArchonInboxDismissals.key)

        XCTAssertEqual(ArchonInboxDismissals.load(from: defaults), ArchonInboxDismissals())
    }
}
