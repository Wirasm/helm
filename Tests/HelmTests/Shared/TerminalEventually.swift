import AppKit
import GhosttyTerminal
import XCTest

/// **Waiting on an observable, with a ceiling — never on a duration.**
///
/// The keyboard and click-routing suites drive a real ghostty surface through a real
/// responder chain, and every interesting step of that is asynchronous: SwiftUI lays out on
/// its own schedule, the surface is created when the view gains a window, and the bytes a
/// keystroke produces come back from ghostty's own thread. A test that waits a *fixed* number
/// of seconds for any of it is betting that the machine is as fast today as it was when the
/// number was chosen — and this repo has now lost that bet three times (#157, the hung-list
/// test in PR #155, and #192).
///
/// The ceiling here is not a tuned delay and must not be trimmed as though it were dead time.
/// It is the point at which we stop believing the answer is coming — and because the loop
/// returns the instant the condition holds, a quiet machine pays only what it actually needs.
/// Generous is therefore free, where a fixed `settle(0.3)` charges every run the full 0.3s
/// and *still* fails the moment the machine is busier than the author's was.
@MainActor
enum Eventually {
    /// How long to keep believing an asynchronous step is still coming.
    ///
    /// `nonisolated` so the failure messages that quote it can be built anywhere.
    nonisolated static let ceiling: TimeInterval = 15

    /// Pump the main runloop until `condition` holds. Returns whether it did.
    ///
    /// The runloop has to run rather than the thread sleep: everything being waited for here
    /// — SwiftUI's update, AppKit's layout, ghostty's display-link tick — is delivered *on*
    /// this runloop, so a sleeping wait would guarantee the timeout it is trying to avoid.
    @discardableResult
    static func holds(
        within ceiling: TimeInterval = Eventually.ceiling, _ condition: () -> Bool
    ) -> Bool {
        if condition() { return true }
        let deadline = Date().addingTimeInterval(ceiling)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if condition() { return true }
        }
        return condition()
    }

    /// Let the hierarchy run for a moment with nothing in particular to wait for.
    ///
    /// Used only where there is genuinely no observable — a *negative* claim ("this redraw
    /// changed nothing"), which has no edge to wait for by definition. Everywhere an
    /// observable exists, `holds(within:_:)` is the tool, and this is not a substitute for it.
    static func pump(_ seconds: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

/// A terminal whose surface never came up, told apart from a terminal that has one and did
/// not receive the keystroke.
///
/// **These are the same red and they are not the same bug**, and conflating them is what
/// #192 cost: ten tests failed with `the keystroke never reached the shell; pty saw
/// <nothing>` — a sentence that reads as a focus bug — when what had actually happened is
/// that `ghostty_surface_new` refused and there was no terminal to type into at all. Two
/// separate investigations went looking for a responder mechanism that was working the whole
/// time, and a diff that touched neither `Terminals/` nor `Workbench/` was blamed for it.
struct MissingTerminalSurface: Error, CustomStringConvertible {
    let pane: UUID
    /// The budget actually spent, not the module's default — a message that quotes a number
    /// nobody waited is how a reader starts doubting the rest of it.
    let waited: TimeInterval

    var description: String {
        """
        the terminal surface for pane \(pane) never came up within \(waited)s, so \
        no keystroke could reach it and no focus assertion below means anything.

        THIS IS NOT A FOCUS BUG AND PROBABLY NOT YOUR DIFF. ghostty_surface_new refused to \
        create the surface. It says why in the unified log, which outlives the test run:

            log show --last 30m --style compact \
        --predicate 'subsystem == "com.mitchellh.ghostty"'

        Look for `embedded_window: error initializing surface`. If it is there, every \
        keystroke assertion in this suite will fail for that reason alone, on any tree, \
        including trees that were green an hour ago — measured in #192.
        """
    }
}

extension InMemoryTerminalSession {
    /// Whether ghostty has built this session's surface yet.
    ///
    /// `readViewportText()` is the observable: it returns `nil` with no surface attached and a
    /// string (empty, for a fresh grid) once there is one. Asked rather than assumed, because
    /// surface creation is asynchronous *and* fallible — the wrapper retries it on every
    /// layout pass and gives up silently when ghostty refuses.
    var hasSurface: Bool { readViewportText() != nil }
}

extension Pty {
    /// Wait for `text` to arrive from the terminal, then report whether it did.
    ///
    /// The keystroke's journey is host → ghostty → ghostty's own thread → this closure, so
    /// arrival is never synchronous with `sendEvent` and how long it takes is the machine's
    /// business, not the test's.
    @MainActor
    func received(_ text: String, within ceiling: TimeInterval = Eventually.ceiling) -> Bool {
        Eventually.holds(within: ceiling) { self.received.contains(text) }
    }
}
