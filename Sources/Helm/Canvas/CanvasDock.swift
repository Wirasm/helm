import SwiftUI

/// The canvas as helm shows it today: one pane in the right dock.
///
/// This is deliberately the *presentation* only — opening is the model's job
/// (`ArtifactPaneModel` subscribes to `helmOpenArtifactFile` itself), because a
/// receiver living here would be gone exactly when the dock is closed and the
/// command needs to open it.
///
/// The shape it is heading for is N canvases as workbench tenants rather than one
/// docked pane, so the dock is a one-slot bench, not a separate concept. Keeping
/// the chrome here means that change lands in the canvas vertical instead of the
/// app shell.
struct CanvasDock: View {
    @ObservedObject var model: ArtifactPaneModel
    @AppStorage("helmDockWidth") private var dockWidth = 560.0

    var body: some View {
        ArtifactPane(model: model)
            .frame(
                minWidth: 360, idealWidth: dockWidth, maxWidth: .infinity,
                maxHeight: .infinity
            )
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size.width) { _, width in
                        dockWidth = width
                    }
                }
            )
            .onExitCommand { model.close() }
    }
}
