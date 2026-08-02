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
    ///
    /// It keeps the name it has at every other stop on the way down, and turns into the
    /// imperative `claimsKeyboard` exactly where it stops being state and becomes an action
    /// against AppKit — the same shape `isVisible` has, which stays `isVisible` all the way
    /// here and only becomes `setSurfaceVisible(_:)` at this boundary.
    let holdsKeyboard: Bool

    func makeNSView(context _: Context) -> FocusClaimingTerminalView {
        view
    }

    func updateNSView(_ view: FocusClaimingTerminalView, context _: Context) {
        // Always visible: the terminal is the frame's permanent center now
        // (the old kild face that occluded it is gone).
        view.setSurfaceVisible(true)
        // Set, never acted on here. When the claim is honoured is the view's business,
        // because only the view is told when it gains a window — see below.
        view.claimsKeyboard = holdsKeyboard
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
/// finds `window == nil` a beat later and returns, and **nothing ever tries again**.
///
/// Measured on a real build rather than reasoned about: the new view's `updateNSView` logged
/// `window=nil`, its hop bailed silently, and `updateNSView` was not called again for that
/// view — nothing re-rendered that pane's subtree, so the retry the old comment counted on
/// ("`updateNSView` re-runs on every poll-driven re-render") never came. The window sat as
/// its own first responder from then on and every character typed went nowhere, with a
/// cursor blinking in a pane that looked focused. Whether SwiftUI *could* have called it
/// again is beside the point: a claim that only lands if something else happens to redraw is
/// not a claim.
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
    ///
    /// `fileprivate(set)` because "pushed by `GhosttyHostView`" should be a fact the compiler
    /// keeps rather than a comment: a second writer anywhere in the module could put two
    /// views in the claiming state at once, which is the bug class this type exists to close.
    fileprivate(set) var claimsKeyboard = false {
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

    /// Takes the keyboard, or says why it could not.
    ///
    /// The two `guard` refusals are genuinely nothing-to-do: `window == nil` is the way OUT
    /// of a window, and already being first responder is the ordinary case on the second
    /// edge. **The third path is not**, and it is the one worth naming: `makeFirstResponder`
    /// returns `false` when the current responder declines to resign, and the result is
    /// `@discardableResult` — so discarding it would rebuild the exact silent failure this
    /// type was written to remove, one call deeper. It is sticky, too: `claimsKeyboard` is
    /// already `true`, so the `didSet` edge will not fire again, and nothing retries until
    /// the view leaves and rejoins a window or focus moves away and back.
    ///
    /// Logged rather than retried. A responder that refuses to resign is refusing for a
    /// reason — a field mid-validation — and a retry loop would fight it; what was missing
    /// was not persistence but any trace at all.
    private func claimKeyboard() {
        guard claimsKeyboard, let window, window.firstResponder !== self else { return }
        guard window.makeFirstResponder(self) else {
            NSLog(
                "helm: terminal could not take the keyboard — %@ refused to resign first responder",
                String(describing: window.firstResponder))
            return
        }
    }
}
