import AppKit
import SwiftUI

/// The one thing `HELM_DEFAULTS_SUITE` cannot move on its own: the window frame.
///
/// A suite catches everything helm writes, because every one of those writes goes through
/// `DefaultsDomain.store`. It catches nothing AppKit writes on helm's behalf, and AppKit
/// writes one thing that matters — the frame, under a key SwiftUI derives from the *content
/// view's type*:
///
///     NSWindow Frame SwiftUI.ModifiedContent<Helm.RootView, SwiftUI._FlexFrameLayout>-1-AppWindow-1
///
/// The type is the same in every build of this source, so an isolated instance would land on
/// the operator's own key and move their window. Small next to a lost tab row, and still the
/// difference between "nothing helm writes reaches `com.wirasm.helm`" being true and being
/// nearly true.
///
/// So an isolated instance stops saving its frame. It still *reads* the one already stored —
/// the restore happens before any view has a window to be told about — which is a read and
/// costs nothing; it just opens where the operator's window last was and then forgets. A test
/// instance has no window position worth keeping, and the operator's survives it.
///
/// Nothing happens when the variable is unset — no window is touched, and the frame is saved
/// and restored exactly as it always has been.
extension View {
    func isolatedInstanceWindow() -> some View {
        background(IsolatedInstanceWindow())
    }
}

private struct IsolatedInstanceWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> IsolatedInstanceWindowView {
        IsolatedInstanceWindowView(frame: .zero)
    }

    func updateNSView(_ view: IsolatedInstanceWindowView, context: Context) {}
}

/// `viewDidMoveToWindow` for the reason `WindowOpacityView` gives at length: a hop off
/// `updateNSView` makes "no window yet" and "no window ever" the same silent return, and this
/// is a job with nothing downstream to notice it was skipped.
///
/// **Clearing it once is not enough, and that was measured rather than reasoned about.** An
/// isolated instance that cleared the name in `viewDidMoveToWindow` alone still wrote
/// `NSWindow Frame SwiftUI.ModifiedContent<…>-1-AppWindow-1` into `com.wirasm.helm` — because
/// SwiftUI assigns the name itself, and does it *after* the view tree is in the window. So the
/// one-shot clear lands first and is overwritten. `didUpdateNotification` is the re-ask:
/// AppKit posts it on every pass through the event loop for a live window, so a name SwiftUI
/// re-applies is cleared again long before the next move can save under it.
final class IsolatedInstanceWindowView: NSView {
    /// The window the re-ask is currently watching.
    ///
    /// Tracked rather than a "have I registered yet" flag, because those are different
    /// questions the moment a view is put in a *second* window: a flag leaves the observer
    /// bound to the first one, so the new window gets the one-shot clear and never the
    /// re-ask — which is precisely the half of this that was measured to be insufficient.
    /// `weak` so a closed window is not held open by its own watcher.
    private weak var observed: NSWindow?

    /// Whether this instance is deliberately not the operator's.
    ///
    /// A closure rather than a direct read of `DefaultsDomain.isIsolated`, for the reason
    /// `TerminalNotifier.canDeliver` gives: **pulled out so the rule is reachable from `swift
    /// test`.** The real answer resolves once per process from the environment, and `swift
    /// test` runs with `HELM_DEFAULTS_SUITE` unset — so with the read inlined, everything
    /// below is dead code under test, which is how the one behaviour in this change that was
    /// tuned by observation ended up with nothing guarding it.
    ///
    /// Set before the view is put in a window; `viewDidMoveToWindow` is what reads it.
    var isIsolatedInstance: () -> Bool = { DefaultsDomain.isIsolated }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // nil on the way out, which is a real call and not a failure.
        guard let window, isIsolatedInstance() else { return }

        disableFrameAutosave(window)
        guard observed !== window else { return }
        if let observed {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didUpdateNotification, object: observed)
        }
        observed = window
        // The selector form rather than the block form: its observer is zeroing-weak, so it
        // goes when this view does and there is no token to remember to remove.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidUpdate(_:)),
            name: NSWindow.didUpdateNotification, object: window)
    }

    @objc private func windowDidUpdate(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        disableFrameAutosave(window)
    }

    /// An empty name is AppKit's own "do not autosave this window". Guarded so the common
    /// case — already cleared, several times a second — is a string check and no work.
    private func disableFrameAutosave(_ window: NSWindow) {
        guard !window.frameAutosaveName.isEmpty else { return }
        window.setFrameAutosaveName("")
    }
}
