import SwiftUI

/// A pane benchd's document holds in a kind this build does not know (#354, AC6): the daemon
/// owns the pane, so helm keeps it where it is and says what it cannot show, rather than
/// dropping it and disagreeing with benchd about what is on the bench.
@MainActor
final class UnsupportedPaneKind: SurfaceKind {
    final class Model {
        let kind: String
        init(kind: String) { self.kind = kind }
    }

    let kind: Pane.Content.Kind = .unsupported
    let survivesUnmount = false

    func make(for pane: Pane, in workspace: WorkspacePath?) -> Model? {
        guard case let .unsupported(kind) = pane.content else { return nil }
        return Model(kind: kind)
    }

    func view(of model: Model, in slot: SurfaceSlot) -> AnyView {
        AnyView(
            VStack(spacing: 6) {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Color.textFaint)
                Text("This build cannot show `\(model.kind)`")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surface))
    }

    func tab(of model: Model, in slot: SurfaceSlot) -> AnyView {
        AnyView(
            PaneTab(
                title: slot.pane.name.text ?? model.kind, truncation: .tail,
                closeHelp: "Close this pane", slot: slot
            ) {
                Image(systemName: "questionmark.square.dashed").font(.system(size: 10))
            })
    }

    func close(_ model: Model) {}
}
