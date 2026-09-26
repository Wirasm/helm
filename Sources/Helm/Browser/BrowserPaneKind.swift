import SwiftUI

/// The shared browser as a `SurfaceKind`: a `BrowserPaneModel`, a view onto the one Chrome benchd
/// supervises (#350), drawn by `BrowserPaneView`.
@MainActor
final class BrowserPaneKind: SurfaceKind {
    /// Injected so a test can point it at a scratch bench root: the default finds the operator's
    /// live browser, and a test that opens a link must not open it there.
    private let makeModel: @MainActor () -> BrowserPaneModel

    init(make: @escaping @MainActor () -> BrowserPaneModel) {
        makeModel = make
    }

    let kind: Pane.Content.Kind = .browser

    func make(for pane: Pane, in workspace: WorkspacePath?) -> BrowserPaneModel? {
        makeModel()
    }

    func view(of model: BrowserPaneModel, in slot: SurfaceSlot) -> AnyView {
        AnyView(BrowserPaneView(model: model, holdsKeyboard: slot.holdsKeyboard))
    }

    func tab(of model: BrowserPaneModel, in slot: SurfaceSlot) -> AnyView {
        AnyView(BrowserTabLabel(model: model, slot: slot))
    }

    /// Closes the view onto the browser, never the browser: agents may be using it.
    func close(_ model: BrowserPaneModel) {
        model.close()
    }
}
