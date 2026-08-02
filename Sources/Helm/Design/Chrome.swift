import AppKit
import SwiftUI

/// Translucent chrome, opaque terminal.
///
/// **The rule, and why it is one-sided.** The bars and tab strips let the desktop through;
/// the surface under text does not. Translucency behind terminal output costs contrast on
/// exactly the pixels helm exists to render, and helm's centre is a Metal layer that would
/// not participate in the effect anyway — a `NSVisualEffectView` cannot filter a backdrop
/// that a separate renderer is drawing over. So the effect is spent where it is free: the
/// frame around the work, which is also the part doctrine says should recede.
///
/// **It needs the window's help.** `.behindWindow` blending samples what is behind the
/// *window*, which is undefined while the window is opaque — hence `translucentWindow()`
/// below. Everything the chrome does not cover therefore has to paint itself, which is what
/// `RootView`'s `Color.surface` base is for. A region that paints nothing is a hole to the
/// desktop, not a neutral grey.
enum Chrome {
    /// How much of the raised surface is laid over the vibrancy.
    ///
    /// **Measured, not guessed.** A running build was parked over a bright wallpaper and the
    /// composited pixels sampled against the terminal's own `#1c1e21`. At 0.68 the chrome
    /// came out within a couple of levels of a flat bar — the effect was paid for and not
    /// visible. At 0.5 it lands 9 to 17 levels above the surface depending on what is
    /// behind, with the hue shifting toward the wallpaper: the desktop is legibly *back
    /// there* without ever being readable.
    ///
    /// The floor matters more than the ceiling. The chrome has to stay ABOVE the surface
    /// whatever the wallpaper does, or the frame inverts against the terminal on a dark
    /// desktop and the whole hierarchy reads backwards. 0.5 measured +9 at its darkest,
    /// which is the number this is really pinned to.
    ///
    /// One number rather than a per-surface choice, because every piece of chrome — the
    /// workspace bar, a slot's tab strip, a canvas toolbar, the status bar — is the same
    /// altitude. If one of them ever wants a different value, that is a second plane and it
    /// should be a second token here, not a literal at the call site.
    static let tint: Double = 0.5
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

/// `NSVisualEffectView` in behind-window mode, which SwiftUI's own `Material` is not: a
/// `Material` blurs what is behind it *within* the window, so over an opaque root it
/// produces grey. Only this samples the desktop.
private struct Backdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        // The material meant for exactly this — content that sits over the window's own
        // backdrop rather than over other content.
        view.material = .underWindowBackground
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
