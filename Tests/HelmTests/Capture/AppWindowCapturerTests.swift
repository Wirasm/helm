import AppKit
import XCTest

@testable import Helm

/// Which window a capture means — and, more to the point, when helm refuses to decide.
///
/// **Two helms is the normal state while building helm**, and one of them is the operator's
/// live session. `winshot` cannot tell them apart at all: it matches owner names by substring,
/// so a worktree build and the operator's window are the same row (`AGENTS.md`). helm is inside
/// the process and can name every candidate, so the ambiguous case is a refusal that lists
/// them rather than a coin flip that hands back a picture of somebody else's work.
@MainActor
final class AppWindowCapturerTests: XCTestCase {
    private var made: [NSWindow] = []

    override func tearDown() async throws {
        for window in made { window.close() }
        made = []
    }

    /// A real `NSWindow`, because the selection is about `isVisible` and `title` and a stand-in
    /// protocol would be testing the stand-in.
    ///
    /// `isReleasedWhenClosed` is off deliberately: it defaults to **true**, and with ARC also
    /// holding the window that is a double free — `tearDown` took the whole test process down
    /// with SIGSEGV before this line existed. An unshown window is already `isVisible == false`,
    /// so "not visible" needs no `orderOut`.
    private func window(_ title: String, visible: Bool = true) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = title
        if visible { window.orderBack(nil) }
        made.append(window)
        return window
    }

    private func refusal(
        _ windows: [NSWindow], key: NSWindow? = nil, named: String? = nil
    ) -> String? {
        if case .failure(let refusal) = AppWindowCapturer.target(
            in: windows, key: key, named: named)
        {
            return refusal.reason
        }
        return nil
    }

    func testOneVisibleWindowNeedsNoKeyWindowAtAll() throws {
        // The headless case, and the one that matters most: over ssh, on another Space or with
        // the screen locked there IS no key window, and a single window is still unambiguous.
        let only = window("helm")
        let chosen = try AppWindowCapturer.target(in: [only], key: nil, named: nil).get()
        XCTAssertIdentical(chosen, only)
    }

    func testNoVisibleWindowIsRefusedVisiblyRatherThanCapturedEmpty() {
        // #174 asks for this case by name: a capture of a window that does not exist is
        // refused, not answered with a blank PNG.
        XCTAssertNotNil(refusal([]))
        XCTAssertNotNil(refusal([window("helm", visible: false)]))
    }

    func testTheKeyWindowSettlesItWhenThereAreSeveral() throws {
        let first = window("helm")
        let second = window("helm — helm-bench")
        let chosen = try AppWindowCapturer.target(in: [first, second], key: second, named: nil)
            .get()
        XCTAssertIdentical(chosen, second)
    }

    func testSeveralWindowsAndNoKeyIsRefusedWithTheirTitles() throws {
        let reason = try XCTUnwrap(
            refusal([window("helm"), window("helm — helm-bench")]))
        // The refusal has to be actionable: a caller that cannot see the screen learns both
        // the titles and the flag that picks one.
        XCTAssertTrue(reason.contains("helm — helm-bench"))
        XCTAssertTrue(reason.contains("window"))
    }

    func testANamedWindowPicksBetweenThemCaseInsensitively() throws {
        let operatorWindow = window("helm")
        let isolated = window("helm — helm-issue174")
        let chosen = try AppWindowCapturer.target(
            in: [operatorWindow, isolated], key: operatorWindow, named: "ISSUE174"
        ).get()
        // The name beats the key window, which is what makes it useful: an agent capturing its
        // own isolated instance is by definition not the one the operator is typing into.
        XCTAssertIdentical(chosen, isolated)
    }

    func testANameThatMatchesNothingOrEverythingIsRefused() {
        let first = window("helm — a")
        let second = window("helm — b")
        XCTAssertNotNil(refusal([first, second], named: "nowhere"))
        // Two matches is not "pick the first": that is the silent wrong window again.
        XCTAssertNotNil(refusal([first, second], named: "helm"))
    }

    func testACapturerWithNoWindowsFailsWithAReasonRatherThanCrashing() {
        let capturer = AppWindowCapturer(windows: { [] }, keyWindow: { nil })
        guard case .failure(let refusal) = capturer.capture(to: "/tmp/x.png", window: nil) else {
            return XCTFail("a capture with no window must not succeed")
        }
        XCTAssertTrue(refusal.reason.contains("no visible window"))
    }
}
