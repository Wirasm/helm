import GhosttyTerminal
import XCTest

@testable import Helm

/// The wrapper denies every protected clipboard request (an unsafe paste, an `OSC 52` read
/// under ghostty's default `clipboard-read = ask`) unless the surface delegate conforms to
/// `TerminalSurfaceClipboardConfirmationDelegate`. Drop the conformance and nothing fails to
/// compile: a multi-line ⌘V into a program without bracketed paste is silently dropped.
final class TerminalClipboardConfirmationTests: XCTestCase {
    func testTerminalSessionAnswersClipboardConfirmations() {
        XCTAssertTrue(
            (TerminalSession.self as Any.Type)
                is (any TerminalSurfaceClipboardConfirmationDelegate.Type),
            "without this conformance the wrapper denies every protected paste, with no diagnostic"
        )
    }
}
