import AppKit
import GhosttyTerminal
import SwiftUI

// MARK: - GhosttyHostView

/// Thin SwiftUI host for a session-owned terminal NSView. Deliberately does not
/// create the view: it mounts/unmounts the session's instance, so dismantling
/// the representable never tears down the surface or its pty. Callers must set
/// `.id(session.id)` next to it so a tab switch dismantles this representable
/// and makes a fresh one for the other session's view (an NSViewRepresentable
/// can never swap its NSView instance in place).
struct GhosttyHostView: NSViewRepresentable {
    let view: TerminalView

    func makeNSView(context _: Context) -> TerminalView {
        view
    }

    func updateNSView(_ view: TerminalView, context _: Context) {
        // Always visible: the terminal is the frame's permanent center now
        // (the old kild face that occluded it is gone).
        view.setSurfaceVisible(true)
        // Focus, deferred: during a SwiftUI update the view may not be in a
        // window yet, and makeFirstResponder mid-update is unsafe. The claim
        // is deliberately NON-stealing — only when nothing else holds focus
        // (responder == window). updateNSView re-runs on every poll-driven
        // re-render, and grabbing focus each tick would make the sidebar and
        // the chat face's composer untypable. AppKit hands the first responder
        // back to the window when a focused view unmounts (tab switch, pane
        // close), so the terminal reclaims focus exactly then.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if window.firstResponder === window {
                window.makeFirstResponder(view)
            }
        }
    }
}
