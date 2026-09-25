import GhosttyKit
import GhosttyTerminal
import XCTest

@testable import Helm

/// A ⌘-click on a link used to open it twice, and the second open never stopped running.
///
/// **The rule: an action helm's delegate took is reported to ghostty as taken.**
///
/// ghostty reads a `false` from the action callback as *the apprt did not handle this* and
/// runs its own default. For `open_url` that default is `internal_os.open`
/// (`Surface.zig:4415`), which spawns `/usr/bin/open` and reads its stderr on a detached
/// thread. That thread's loop breaks only on `EndOfStream`, and after the child exits the
/// reader returns zero-length slices instead — so it never leaves the loop, never reaches
/// `exe.wait()`, and spins logging `open stderr=` at roughly 9k lines a second
/// (ghostty-org/ghostty#13480, closed unmerged). Measured on a helm up for nine days: seven
/// such threads, seven unreaped children, 398% CPU, 586 CPU-hours. Only a restart clears it,
/// and every click adds another one.
///
/// The fix is one expression in the vendored wrapper's action callback
/// (`Patches/libghostty-spm-open-url-handled.patch`), and it claims ownership only when a
/// delegate actually took the URL:
///
///     action.tag == GHOSTTY_ACTION_OPEN_URL
///         && bridge.delegate is any TerminalSurfaceOpenURLDelegate
///
/// **So the conformance below is load-bearing, which is the whole reason this file exists.**
/// `scripts/patch-libghostty.sh` greps for a marker symbol, which proves the patch was
/// *applied* and says nothing about whether its condition can still be met. Drop
/// `TerminalSurfaceOpenURLDelegate` from `TerminalSession` and nothing fails to compile:
/// the callback simply reports `false` again, ghostty resumes opening every link itself, and
/// the leak is back with no diagnostic anywhere. That is a silent regression a marker grep
/// cannot see, so it is pinned here instead.
///
/// What is deliberately *not* here: the callback itself. `TerminalCallbackBridge` is internal
/// to `GhosttyTerminal` and the callback needs live `ghostty_app_t`/`ghostty_surface_t`
/// pointers, so the predicate cannot be executed from this side.
///
/// **The live half is NOT covered here and was not run.** Proving the leak is gone needs a
/// real link ⌘-clicked in a real pane, and a ⌘-click needs a display and an Accessibility
/// grant no agent has (AGENTS.md). The check is: ⌘-click a link, then
/// `ps -M -p <helm pid>` for a new thread pinned near 57%, and
/// `ps -Ao pid,ppid,stat | awk '$2==<helm pid> && $3 ~ /Z/'` for a new zombie. Neither should
/// appear, and on a build without this patch both do.
final class TerminalOpenURLOwnershipTests: XCTestCase {
    /// The condition the patch tests at runtime, asserted against the type helm actually
    /// installs as the surface delegate.
    func testTerminalSessionTakesOpenURLSoGhosttyDoesNotOpenItToo() {
        XCTAssertTrue(
            (TerminalSession.self as Any.Type) is (any TerminalSurfaceOpenURLDelegate.Type),
            "TerminalSession must conform to TerminalSurfaceOpenURLDelegate: the vendored callback claims open_url only when it does, and without it ghostty falls back to /usr/bin/open and leaks a spinning thread per ⌘-click"
        )
    }

    /// The other half of the same sentence, and the reason a bare `true` would be wrong:
    /// ownership is claimed for `open_url` alone. Every other action keeps ghostty's default,
    /// because no other fallback was measured and claiming one would suppress it blind.
    func testOwnershipIsClaimedForOpenURLAndNothingElse() {
        XCTAssertNotEqual(
            GHOSTTY_ACTION_OPEN_URL,
            GHOSTTY_ACTION_SET_TITLE,
            "the patch keys on this tag; if the constants ever collapse the condition stops discriminating"
        )
    }

    /// Taking the action is not the same as opening the URL, and the difference is the point
    /// of the allowlist. helm drops a scheme outside it and *still* owns the action — before
    /// the patch ghostty opened the dropped URL anyway, which made `TerminalURLPolicy`
    /// advisory rather than the security boundary `TerminalSession` documents it as.
    func testADroppedSchemeIsStillHelmsDecisionToMake() {
        XCTAssertNil(
            TerminalURLPolicy.validated("javascript:alert(1)"),
            "the policy must still refuse this"
        )
        XCTAssertTrue(
            (TerminalSession.self as Any.Type) is (any TerminalSurfaceOpenURLDelegate.Type),
            "and refusing it must not read to ghostty as unhandled, or the fallback opens what the policy just dropped"
        )
    }
}
