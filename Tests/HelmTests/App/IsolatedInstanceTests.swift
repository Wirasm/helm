import AppKit
import XCTest

@testable import Helm

/// The window frame is the one write `HELM_DEFAULTS_SUITE` cannot move on its own, and the
/// suppression that stops it was tuned by observation rather than derived from a rule:
/// clearing the autosave name once in `viewDidMoveToWindow` was **measured** leaking an
/// isolated instance's geometry into `com.wirasm.helm`, because SwiftUI assigns that name
/// after the view is in the window.
///
/// So what these pin is the **re-ask**, not the clear. An observer on
/// `didUpdateNotification` sitting beside a `viewDidMoveToWindow` that already does the same
/// thing reads as redundant — it is exactly what a later tidy-up would delete — and this is
/// what says otherwise.
///
/// A real `NSWindow` under test is the established pattern here; `TerminalKeyboardTests`
/// builds one to push `NSEvent`s through the responder chain.
@MainActor
final class IsolatedInstanceTests: XCTestCase {
    private func window(autosavedAs name: String? = nil) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let name { window.setFrameAutosaveName(name) }
        return window
    }

    /// `isIsolatedInstance` is injected because `DefaultsDomain.isIsolated` resolves once per
    /// process from the environment, and `swift test` runs with the variable unset — so with
    /// the read inlined, every branch below is unreachable and this file stays untested.
    private func attachedView(isolated: Bool, to window: NSWindow) {
        let view = IsolatedInstanceWindowView(frame: .zero)
        view.isIsolatedInstance = { isolated }
        window.contentView = view
    }

    func testAnIsolatedInstanceStopsAutosavingItsFrame() {
        let window = window(autosavedAs: "helm-tests-autosave")
        XCTAssertEqual(window.frameAutosaveName, "helm-tests-autosave", "precondition")

        attachedView(isolated: true, to: window)

        XCTAssertEqual(
            window.frameAutosaveName, "",
            "an isolated instance must not save its frame — that key is the operator's")
    }

    /// The regression the observer exists for, and the one a one-shot clear loses to.
    func testANameReappliedAfterTheViewLandedIsClearedAgain() {
        let window = window(autosavedAs: "helm-tests-autosave")
        attachedView(isolated: true, to: window)
        XCTAssertEqual(window.frameAutosaveName, "", "precondition: cleared on the way in")

        // What SwiftUI does a beat later, under the name it derives from the content view.
        window.setFrameAutosaveName("SwiftUI.ModifiedContent<Helm.RootView>-1-AppWindow-1")
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

        XCTAssertEqual(
            window.frameAutosaveName, "",
            "a name re-applied after the view landed must be cleared again, or the leak is back")
    }

    /// The default path, and the one that must not change: with the variable unset helm goes
    /// on remembering where its window was, exactly as it always has.
    func testAnOrdinaryInstanceKeepsItsFrameAutosave() {
        let window = window(autosavedAs: "helm-tests-autosave")

        attachedView(isolated: false, to: window)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

        XCTAssertEqual(
            window.frameAutosaveName, "helm-tests-autosave",
            "nothing here may touch a window that is not an isolated instance's")
    }
}
