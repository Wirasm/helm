import GhosttyKit
import GhosttyTerminal
import XCTest

/// #297 — a program in a pane could replace the operator's system clipboard by emitting
/// `OSC 52` at the selection target.
///
/// **The rule: helm has one clipboard, and a program writes the one it asked for. A write
/// naming a clipboard this platform does not have is refused, not redirected.**
///
/// A *write*-side rule on purpose. ghostty resolves an `OSC 52` read to the standard
/// clipboard itself, before any callback runs (`Surface.zig:1049`), so there is no read
/// destination left for a host to govern — `docs/VENDORED.md` carries that measurement and
/// the reason the symmetric guard is a trap rather than an omission.
///
/// It lives one layer down, in the vendored wrapper's clipboard callback, because that is
/// the only place the destination argument exists — `Patches/libghostty-spm-clipboard-destination.patch`,
/// recorded in `docs/VENDORED.md`. These tests are here anyway, and that is the point:
/// `scripts/patch-libghostty.sh` can only grep for a marker symbol, which proves the patch
/// was *applied* and says nothing about what it decides. This executes the decision from
/// helm's own gate, so a re-clone, a rebase of the patch onto a newer tag, or a well-meant
/// edit to the wrapper fails a test here rather than quietly handing the operator's
/// clipboard back to whatever is running in a pane.
///
/// The live half — a real program in a real pane, a sentinel on `NSPasteboard.general`,
/// read back before and after — cannot be reached from a unit test and is in the PR. Note
/// what is deliberately absent below: nothing here touches the real pasteboard.
/// `PasteboardTests` states the reason for the whole suite — *"`NSPasteboard.general` is the
/// operator's real clipboard and a test has no business clearing it"* — and this rule is
/// checkable without one, because it is a property of the request rather than of the write.
final class TerminalClipboardDestinationTests: XCTestCase {
    func testTheStandardClipboardIsTheOneThisPlatformHas() {
        let destination = TerminalClipboardDestination(GHOSTTY_CLIPBOARD_STANDARD)
        XCTAssertEqual(destination, .standard)
        XCTAssertTrue(
            destination.isSupported,
            "OSC 52 at the clipboard target is a capability that legitimately exists — nvim, tmux and ssh set the system clipboard this way, and every other macOS terminal allows it"
        )
    }

    func testTheSelectionClipboardIsRefusedRatherThanRedirected() {
        let destination = TerminalClipboardDestination(GHOSTTY_CLIPBOARD_SELECTION)
        XCTAssertEqual(destination, .selection)
        XCTAssertFalse(
            destination.isSupported,
            "macOS has no selection clipboard. Answering with the system one is #297: a program that never asked for the operator's clipboard replaces it, silently"
        )
    }

    /// `primary` is the case that proves a decoder is needed rather than a boolean.
    /// `ghostty.h` declares two constants; ghostty's own `apprt.Clipboard` has three
    /// (`standard = 0`, `selection = 1`, `primary = 2`) and passes `@intFromEnum` straight
    /// across the boundary. So this value crosses the FFI with no C constant to name it —
    /// and before the patch it reached `NSPasteboard.general` like everything else.
    func testThePrimaryClipboardArrivesAsAValueTheCHeaderCannotName() {
        XCTAssertEqual(
            ghostty_clipboard_e(rawValue: 2).rawValue,
            2,
            "if a third constant ever appears in ghostty.h this test should be re-read, not re-pinned"
        )
        let destination = TerminalClipboardDestination(ghostty_clipboard_e(rawValue: 2))
        XCTAssertEqual(destination, .primary)
        XCTAssertFalse(destination.isSupported)
    }

    func testAKindThisBuildDoesNotModelIsRefusedNeverFoldedIntoStandard() {
        let destination = TerminalClipboardDestination(ghostty_clipboard_e(rawValue: 99))
        XCTAssertEqual(destination, .unknown(99))
        XCTAssertFalse(
            destination.isSupported,
            "folding an unrecognised destination into the standard clipboard would be the same defect wearing a new name"
        )
    }

    /// The rule in one assertion: exactly one destination is writable, and it is the one
    /// the platform actually has.
    func testExactlyOneDestinationIsSupported() {
        let all: [TerminalClipboardDestination] = [.standard, .selection, .primary, .unknown(7)]
        XCTAssertEqual(all.filter(\.isSupported), [.standard])
    }
}
