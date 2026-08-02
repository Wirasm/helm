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
    let view: FocusClaimingTerminalView
    /// Whether the bench says this pane is the focused one — helm's *intent* that this
    /// terminal own the keyboard. Passed down as a value rather than asked of a model,
    /// so the only thing this representable does is forward it.
    let claimsKeyboard: Bool

    func makeNSView(context _: Context) -> FocusClaimingTerminalView {
        view
    }

    func updateNSView(_ view: FocusClaimingTerminalView, context _: Context) {
        // Always visible: the terminal is the frame's permanent center now
        // (the old kild face that occluded it is gone).
        view.setSurfaceVisible(true)
        // Set, never acted on here. When the claim is honoured is the view's business,
        // because only the view is told when it gains a window — see below.
        view.claimsKeyboard = claimsKeyboard
    }
}

// MARK: - FocusClaimingTerminalView

/// The vendor's terminal NSView plus the one thing helm has to hear from AppKit directly:
/// *this view is now in a window*.
///
/// **This is issue #96, and the shape of the bug is worth keeping.** Focus used to be
/// claimed from a `DispatchQueue.main.async` hop out of `updateNSView`, guarded by
/// `guard let window = view.window else { return }`. For the first terminal that works —
/// the view lands in the window within a runloop turn. For a terminal created by ⌘N it does
/// not: SwiftUI runs `updateNSView` while the new pane's view is still window-less, the hop
/// finds `window == nil` a beat later and returns, and **nothing ever tries again** — the
/// representable's only other input never changes, so SwiftUI has no reason to update it.
/// Measured on a real build: the new view's update logged `window=nil`, its hop bailed
/// silently, and the window sat as its own first responder from then on. Every character
/// typed after that went nowhere, with a cursor blinking in a pane that looked focused.
///
/// `viewDidMoveToWindow` is the signal that question actually has. `Chrome.swift`'s
/// `WindowOpacityView` already made this exact argument for the window's opacity — *"the
/// window was not there yet" and "the window is never coming" are the same silent return* —
/// and this is the same failure one slice over.
///
/// **Both entry points are edges, and that is what keeps the composer typable.** The old
/// claim had to be non-stealing (`firstResponder === window`) because it ran on every
/// re-render; grabbing focus each tick would have made the chat composer and the workspace
/// bar untypable. Nothing here runs on a re-render: a window change is a real AppKit event,
/// and `claimsKeyboard` only acts on `false → true`. Clicking into the composer moves the
/// first responder and neither edge fires, so the terminal does not snatch it back.
final class FocusClaimingTerminalView: TerminalView {
    /// Helm's intent: the bench's focused pane is this one. Pushed by `GhosttyHostView`.
    ///
    /// Acting on the transition rather than the value is deliberate — see the header. It
    /// covers ⌘⌥+arrow, which moves focus between slots without remounting anything, so
    /// there is no window change to hear.
    var claimsKeyboard = false {
        didSet {
            guard claimsKeyboard, !oldValue else { return }
            claimKeyboard()
        }
    }

    /// Called by AppKit exactly when this view gains (or loses) a window. Covers every way
    /// a terminal arrives on screen: created by ⌘N, selected by ⌘1–9, restored at launch,
    /// or mounted by a workspace switch.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimKeyboard()
    }

    /// Takes the keyboard, or does nothing at all. Silent by design in both refusals:
    /// `window == nil` is the way OUT of a window, and already being first responder is the
    /// ordinary case on the second edge.
    private func claimKeyboard() {
        guard claimsKeyboard, let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }
}
