import XCTest

@testable import Helm

/// When a desktop notification may be delivered at all.
///
/// `UNUserNotificationCenter.current()` **aborts** for a process with no real bundle — it does
/// not throw, so nothing downstream can catch it. The only defence is not calling it, which is
/// why the decision lives in a pure function rather than inside the lazy `center` accessor.
final class TerminalNotifierTests: XCTestCase {
    /// The regression: this guard asked `bundleIdentifier != nil` until #45 gave the SPM binary
    /// an identifier so both launch paths would share one `UserDefaults` domain. The guard then
    /// started passing under `swift run` while the abort remained, and helm died with
    /// `bundleProxyForCurrentProcess is nil` the first time an agent asked for a notification —
    /// taking every session it hosted down with it.
    func testABareSPMBinaryMayNotDeliver() {
        XCTAssertFalse(
            TerminalNotifier.canDeliver(
                from: URL(fileURLWithPath: "/Users/x/helm/.build/arm64-apple-macosx/debug")),
            "an identifier is not a bundle; calling current() here aborts the process")
    }

    func testARealAppBundleMayDeliver() {
        XCTAssertTrue(
            TerminalNotifier.canDeliver(from: URL(fileURLWithPath: "/Applications/Helm.app")))
    }

    // MARK: - The gate

    /// The rule the bench renamed: `tabIsSelected` → `paneIsVisible`. Same truth table —
    /// the only change is that the question now has one answer per session, where
    /// "selected" answers for only one of the several panes on screen at once.
    ///
    /// Written here rather than merely relabelled: the gate had no test, so the rename
    /// would otherwise have moved an untested rule.
    func testANotificationFromThePaneYouAreLookingAtIsSuppressed() {
        XCTAssertFalse(
            TerminalNotificationGate.shouldDeliver(appIsActive: true, paneIsVisible: true),
            "you watched it happen; a banner about it is noise")
    }

    func testANotificationFromAPaneYouCannotSeeIsDelivered() {
        XCTAssertTrue(
            TerminalNotificationGate.shouldDeliver(appIsActive: true, paneIsVisible: false),
            "an off-screen pane asking for attention is the entire point")
    }

    func testABackgroundedAppAlwaysDelivers() {
        XCTAssertTrue(
            TerminalNotificationGate.shouldDeliver(appIsActive: false, paneIsVisible: true),
            "visible in a helm nobody is looking at is not visible")
        XCTAssertTrue(
            TerminalNotificationGate.shouldDeliver(appIsActive: false, paneIsVisible: false))
    }
}
