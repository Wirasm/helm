import AppKit
import Combine
import XCTest

@testable import Helm

/// The one rule `TerminalFocusWatch` has, and the reason its design works at all.
@MainActor
final class TerminalFocusWatchTests: XCTestCase {
    /// **The dedup is the whole design, so it is worth a test.** `didUpdate` fires freely —
    /// it brackets every event a window handles — and the watch subscribes to it precisely
    /// because it is the only public signal that covers a first-responder change. What keeps
    /// that from re-rendering the status bar on every keystroke the operator types into the
    /// terminal is the guard in `refresh`, and nothing else. Republishing unconditionally
    /// would still be *correct*, which is exactly why the regression would go unnoticed.
    ///
    /// A manager with no sessions answers `anyTerminalHasFocus` the same way every time, so
    /// the value genuinely does not change across the posts below.
    func testUnchangedFocusNeverTouchesThePublisher() {
        // `anyTerminalHasFocus` reads `NSApp.keyWindow`, and `NSApp` is nil until something
        // has asked for the shared application. Headless test runners have not.
        _ = NSApplication.shared

        let watch = TerminalFocusWatch(manager: TerminalManager())
        var publishes = 0
        let subscription = watch.$terminalFocused.sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        XCTAssertEqual(publishes, 1, "a @Published sink replays the current value on subscribe")

        for name in [
            NSWindow.didUpdateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.post(name: name, object: nil)
            NotificationCenter.default.post(name: name, object: nil)
        }

        XCTAssertEqual(
            publishes, 1,
            "six notifications with no focus change must not publish once"
        )
        XCTAssertFalse(watch.terminalFocused, "no sessions means no terminal holds the keyboard")
    }
}
