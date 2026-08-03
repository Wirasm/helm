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
final class IsolatedInstanceWindowView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // nil on the way out, which is a real call and not a failure.
        guard let window, DefaultsDomain.isIsolated else { return }

        // An empty name is AppKit's own "do not autosave this window", and it is the whole
        // change: nothing is written on move, resize or close from here on.
        window.setFrameAutosaveName("")
    }
}
