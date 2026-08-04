import AppKit
import SwiftUI

// MARK: - PaneClickReporter

/// Reports a click landing anywhere in one slot's content, whoever goes on to consume it.
///
/// **helm has two ideas of focus and only one of them used to move.** There is the first
/// responder — which surface has the keyboard, owned by AppKit and ghostty — and there is
/// `Workbench.focusedSlot`, which is what ⌘⇧D, ⌘T, ⌘N, ⌘⌥W, ⌘O and ⌘L act on. Clicking a *tab*
/// moved both, because `SlotTabStrip` calls `model.focus`. Clicking a pane's *body* moved only
/// the first responder, so the operator typed into one pane while every command landed in
/// another, with no error and nothing on screen to say why (#152). ⌘⇧D was the worst of them:
/// the others are no-ops or misplacements, but a split *mutates the layout*.
///
/// **Why a local monitor rather than a tap gesture or a `mouseDown` override.** The tenant
/// consumes the event first — a terminal grid takes mouse-down for selection, a `WKWebView`
/// takes it for the page — so nothing helm puts *in* the responder chain hears the click that
/// matters. `Keymap` already makes this argument for keys: *"a local monitor runs before any
/// view's key handling, so helm's bindings always win"*. The mouse is the same problem and this
/// is the same answer, with the one difference that matters below.
///
/// **It never consumes.** `Keymap` returns nil to keep a keystroke from reaching the pty; this
/// returns the event on every path, so text selection, link clicks and the terminal's own mouse
/// reporting are untouched. The only effect is `onClick`.
///
/// A `becomeFirstResponder` override on `FocusClaimingTerminalView` would cover the grid in
/// fewer lines and leave the canvas with no hook at all — a `WKWebView`'s first responder is its
/// own internal content view, not anything helm owns. One mechanism covering both panes is the
/// smaller thing to keep true.
struct PaneClickReporter: NSViewRepresentable {
    /// Called for every mouse-down inside this view's rectangle, including repeated clicks in
    /// the pane that is already focused. Deciding that such a click changes nothing is
    /// `WorkbenchModel.focus`'s, not this view's — a reporter that filtered would need its own
    /// copy of what the bench already knows.
    let onClick: () -> Void

    func makeNSView(context _: Context) -> ClickWatchingView { ClickWatchingView() }

    /// The closure is rebuilt on every render and captures the slot id, so it is pushed each
    /// time rather than captured once at `makeNSView` — the same shape `GhosttyHostView` uses
    /// for `claimsKeyboard`.
    func updateNSView(_ view: ClickWatchingView, context _: Context) {
        view.onClick = onClick
    }
}

// MARK: - ClickWatchingView

/// An invisible rectangle that knows when a click lands in it.
///
/// **The monitor lives exactly as long as the view is in a window, and `viewDidMoveToWindow` is
/// the signal for both halves.** That is #96's ruling reused rather than re-derived: it is the
/// one event AppKit actually sends when a view arrives and when it leaves, where anything hung
/// off an update can find `window == nil` and never be asked again.
///
/// There is deliberately no `deinit`. A nonisolated deinit may not touch the main-actor state
/// this holds — the same rule that made `WorkbenchModel` keep `AnyCancellable`s rather than
/// observer tokens — and leaving on `viewDidMoveToWindow(nil)` is the earlier, surer edge
/// anyway: the view stops watching when it stops being on screen, not when ARC gets to it.
final class ClickWatchingView: NSView {
    var onClick: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopWatching() } else { startWatching() }
    }

    private func startWatching() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            // The monitor runs on the main thread, so assumeIsolated is safe — `Keymap`
            // installs helm's key monitor the same way and says so for the same reason.
            MainActor.assumeIsolated { self?.report(event) }
            // Never consumed. See the type's header: this watches the mouse, it does not
            // take it.
            return event
        }
    }

    private func stopWatching() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// A click is this slot's when it is in this slot's **window** and lands inside this view.
    ///
    /// The window check is not a formality. ⌘O's artifact browser is a popover, which is its
    /// own window sitting over the bench, and a click in it converts to a point that falls
    /// squarely inside this rectangle. Moving focus to the slot underneath a popover the
    /// operator is using is precisely the misrouting this file exists to remove.
    ///
    /// Compared by **number** rather than by `event.window` identity: the number is carried on
    /// the event itself, where `window` is resolved through AppKit's registry and is nil for a
    /// window that was never ordered on screen — which is every window under `swift test`. The
    /// two say the same thing about a popover; only one of them is answerable in a test.
    private func report(_ event: NSEvent) {
        guard let window, event.windowNumber == window.windowNumber else { return }
        guard focusable.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    /// This slot's rectangle, less the band a divider can be grabbed by.
    ///
    /// **A divider's grab area is an overlay, so it overhangs its neighbours' rectangles** —
    /// deliberately, so the hairline stays a hairline and the target is still hittable. Which
    /// means a mouse-down aimed squarely at a divider lands geometrically inside the pane
    /// beside it, and reading that as *focus this pane* would move the keyboard to a pane the
    /// operator never clicked. Reaching down to resize while typing above would take your next
    /// keystrokes with it: #152 reopened through the resize handle.
    ///
    /// Inset on **every** edge rather than only the ones with a divider on them, because which
    /// edges those are is `SplitStack`'s knowledge and threading it here would buy a few points
    /// of click target at the price of a second thing to keep in step. The cost is that the
    /// outer few points of a pane no longer focus it; the divider is what you are aiming at
    /// there anyway, and a click one pixel further in still lands.
    ///
    /// An inset larger than the view leaves a null rectangle, which `contains` answers false
    /// for — so a pane too small to have a middle refuses rather than guesses.
    private var focusable: NSRect {
        let overhang = (SplitLayout.dividerGrab - SplitLayout.dividerThickness) / 2
        return bounds.insetBy(dx: overhang, dy: overhang)
    }
}
