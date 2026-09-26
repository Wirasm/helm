import GhosttyKit
import XCTest

@testable import GhosttyTerminal

/// #297: a program in a pane could replace the operator's clipboard with `OSC 52` aimed at
/// the selection clipboard, because every write landed on `NSPasteboard.general` whatever it
/// named. The rule is a property of the request, so nothing here touches the real pasteboard.
final class ClipboardWriteTests: XCTestCase {
    func testTheStandardClipboardReachesThePasteboard() {
        XCTAssertTrue(
            TerminalClipboardWrite.reachesPasteboard(GHOSTTY_CLIPBOARD_STANDARD),
            "OSC 52 at the clipboard target is legitimate: nvim, tmux and ssh set it this way")
    }

    func testTheSelectionClipboardIsDroppedNotRedirected() {
        XCTAssertFalse(TerminalClipboardWrite.reachesPasteboard(GHOSTTY_CLIPBOARD_SELECTION))
    }

    /// ghostty's `apprt.Clipboard` has `primary = 2`, which `ghostty.h` does not name.
    func testPrimaryArrivesAsARawValueAndIsDropped() {
        XCTAssertFalse(TerminalClipboardWrite.reachesPasteboard(ghostty_clipboard_e(rawValue: 2)))
    }

    func testAKindThisBuildDoesNotKnowIsDropped() {
        XCTAssertFalse(TerminalClipboardWrite.reachesPasteboard(ghostty_clipboard_e(rawValue: 99)))
    }
}
