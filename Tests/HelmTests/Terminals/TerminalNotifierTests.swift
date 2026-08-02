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
}
