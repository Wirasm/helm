import SwiftUI

/// The canvas as a `SurfaceKind`: a `CanvasModel` over a file, drawn by `CanvasView`.
///
/// `configure` runs once on every model this kind makes. It is how the bench wires the mark
/// route (#205) without the kind knowing about openers or mail: `WorkbenchModel` passes it in,
/// because the bench holds the document that names each canvas's opener.
@MainActor
final class CanvasPaneKind: SurfaceKind {
    private let configure: (CanvasModel, Pane.ID) -> Void
    /// Where every canvas this kind makes reads and writes its files: benchd.
    private let files: any CanvasFiles

    init(files: any CanvasFiles, configure: @escaping (CanvasModel, Pane.ID) -> Void) {
        self.files = files
        self.configure = configure
    }

    let kind: Pane.Content.Kind = .canvas

    func make(for pane: Pane, in workspace: WorkspacePath?) -> CanvasModel? {
        guard case let .canvas(source) = pane.content else { return nil }
        let model = CanvasModel(source: source, files: files)
        configure(model, pane.id)
        return model
    }

    func view(of model: CanvasModel, in slot: SurfaceSlot) -> AnyView {
        AnyView(CanvasView(model: model))
    }

    func tab(of model: CanvasModel, in slot: SurfaceSlot) -> AnyView {
        guard case let .canvas(source) = slot.pane.content else { return AnyView(EmptyView()) }
        return AnyView(CanvasTab(source: source, slot: slot))
    }

    /// Saves a draft being typed (the last moment a save can happen).
    func close(_ model: CanvasModel) {
        model.close()
    }
}

/// A canvas's tab: what it is showing, and no mark. A canvas has no shell to report a bell, an
/// exit code or a progress sequence.
///
/// **Its name comes from the pane, where a terminal's is pushed onto its session**, and the
/// asymmetry is the pane types'. A terminal has an `ObservableObject` that three readers already
/// spend for its label; a canvas has none, and its label is recomputed from `CanvasSource` every
/// render. So a named canvas is named on its tab and absent from `snapshot.json`
/// (`BenchSnapshot.CanvasRecord` has no title); giving it one is that type's change to make.
struct CanvasTab: View {
    let source: CanvasSource
    let slot: SurfaceSlot

    var body: some View {
        PaneTab(
            title: slot.pane.name.text ?? label, truncation: .middle,
            closeHelp: "Close canvas", slot: slot
        ) {
            Image(systemName: "doc.text")
                .font(.system(size: 9))
                .foregroundStyle(Color.textMuted)
        }
    }

    private var label: String {
        switch source {
        case let .file(path): (path.value as NSString).lastPathComponent
        }
    }
}
