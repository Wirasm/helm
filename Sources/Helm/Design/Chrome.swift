import AppKit
import SwiftUI

/// One pane of glass: the whole window is translucent, at two weights.
///
/// **This file used to say "translucent chrome, opaque terminal", and it was wrong.** The
/// reasoning was that SwiftUI vibrancy cannot filter a backdrop a separate renderer draws
/// over — which is true, and which is not the same as the terminal being unable to
/// participate. The operator's verdict on the result was exact: a solid slab inside a
/// translucent frame, and the slab is the part you look at.
///
/// The terminal participates NATIVELY instead. ghostty's own `background-opacity` reaches
/// the Metal layer because the layer is built with `isOpaque = false` and the renderer
/// honours the alpha, so the grid's background is genuinely translucent — and what it
/// composites against is the `TerminalBackdrop` below, which is this same frosted plane.
/// One material, two weights: the chrome tinted up so it reads as a step above, the grid
/// left where text is safest.
///
/// **It needs the window's help.** `.behindWindow` blending samples what is behind the
/// *window*, which is undefined while the window is opaque — hence `translucentWindow()`
/// below. Everything the glass does not cover therefore has to paint itself, which is what
/// `RootView`'s `Color.surface` base is for. A region that paints nothing is a hole to the
/// desktop, not a neutral grey.
enum Chrome {
    /// How much of the raised surface is laid over the vibrancy.
    ///
    /// **Measured, not guessed, and re-measured when the material changed.** A running build
    /// was parked over a bright wallpaper and the composited pixels sampled against the
    /// terminal's own `#1c1e21`. The first pass used `.underWindowBackground`, which
    /// transmits so little that the terminal could not be made to participate without
    /// spending contrast it did not have; `.hudWindow` transmits enough for both. Against
    /// the brighter material 0.5 put the chrome at +28 to +32 — a band that announces
    /// itself, where doctrine says chrome recedes. 0.72 lands it at +6 to +22, a clear step
    /// above the grid's +0 to +8 with both still moving as the wallpaper behind them changes.
    ///
    /// The floor matters more than the ceiling. The chrome has to stay ABOVE the grid
    /// whatever the wallpaper does, or the frame inverts against the terminal on a dark
    /// desktop and the whole hierarchy reads backwards.
    ///
    /// One number rather than a per-surface choice, because every piece of chrome — the
    /// workspace bar, a slot's tab strip, a canvas toolbar, the status bar — is the same
    /// altitude. If one of them ever wants a different value, that is a second plane and it
    /// should be a second token here, not a literal at the call site.
    static let tint: Double = 0.72
}

/// The plane every piece of chrome sits on: vibrancy, with the raised surface over it.
///
/// A view rather than a modifier so it can be handed to `.background(_:)` directly, and so
/// the tint and the backdrop can never be applied one without the other.
struct ChromeBackground: View {
    var body: some View {
        ZStack {
            Backdrop()
            Color.surfaceRaised.opacity(Chrome.tint)
        }
    }
}

/// What a terminal pane floats on: the same frosted plane, **untinted**.
///
/// **Untinted is the whole point, and getting it wrong cancels the effect.** The grid draws
/// its own background at `TerminalSession.backgroundOpacity(in:)` and composites against
/// this, so a surface tint here would be counted twice — 0.86 of the surface over 0.86 of
/// the surface is 0.98 of it, and the translucency the operator asked for would quietly
/// evaporate while every line of the code that produces it still looked right. The one knob
/// is ghostty's.
///
/// The pane's placeholder states — a dead shell, a failed config — have no grid to draw that
/// background, so `TerminalPaneView` lays the surface over this itself at the same value.
struct TerminalBackdrop: View {
    var body: some View {
        Backdrop()
    }
}

/// `NSVisualEffectView` in behind-window mode, which SwiftUI's own `Material` is not: a
/// `Material` blurs what is behind it *within* the window, so over an opaque root it
/// produces grey. Only this samples the desktop.
private struct Backdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        // **Chosen for transmission, and `.underWindowBackground` was tried first.** That is
        // the material nominally meant for this, and it darkens a backdrop so heavily that
        // the grid could not be made to participate at any opacity that left text safe —
        // measured, the terminal moved 1 to 2 luminance levels while the chrome moved 9 to
        // 17. `.hudWindow` passes enough through that a 14% window buys real depth, which is
        // what lets the terminal and the chrome be the same glass at two weights.
        view.material = .hudWindow
        // `.active` rather than `.followsWindowActiveState`: helm's chrome is a frame the
        // operator reads while looking at something else, and a frame that changes weight
        // when the window loses key is motion for nothing.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// Makes the hosting window non-opaque, which is the precondition for any of the above.
    ///
    /// Attached once, by `RootView`. Idempotent, and cheap to re-run: SwiftUI evaluates
    /// `updateNSView` freely and the guard makes every call after the first a no-op.
    func translucentWindow() -> some View {
        background(TranslucentWindow())
    }
}

/// Reaches the `NSWindow` SwiftUI will not hand over. There is no supported `WindowGroup`
/// API for this on macOS 26; verified against the SDK, not assumed.
private struct TranslucentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowOpacityView {
        WindowOpacityView(frame: .zero)
    }

    func updateNSView(_ view: WindowOpacityView, context: Context) {}
}

/// A view whose only job is to answer the question "do I have a window yet".
///
/// **`viewDidMoveToWindow` rather than a hop off `updateNSView`, and the difference is a
/// failure mode.** `makeNSView` is too early — a view has no window until something puts it
/// in one — so the obvious shape is to look again from a `DispatchQueue.main.async` inside
/// `updateNSView`. But then "the window was not there yet" and "the window is never coming"
/// are the same silent `return`, on a path with nothing downstream to notice: the app opens
/// opaque, the chrome quietly loses its vibrancy, and no test, log or crash says so.
///
/// AppKit already has the signal. This is called exactly when the view gains a window, so
/// there is no polling, no retry, and no case where the work is skipped while the app still
/// renders — if it never fires, this view was never on screen at all.
final class WindowOpacityView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // nil on the way OUT, which is a real call and not a failure.
        guard let window, window.isOpaque else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
