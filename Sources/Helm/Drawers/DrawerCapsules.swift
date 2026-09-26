import HelmWire
import SwiftUI

/// One status-bar capsule per drawer that holds something (#356): its name, lit while it is
/// shown, with a dot while an agent has put something in it the operator has not looked at.
/// Clicking one toggles it, as the operator.
///
/// This is how an agent's `pane/open` into a drawer reaches the operator without taking his
/// focus: the drawer is badged, the dot appears, and he opens it when he chooses.
struct DrawerCapsules: View {
    @ObservedObject var model: WorkbenchModel

    var body: some View {
        ForEach(DrawerCapsule.of(model.document)) { capsule in
            Button {
                model.send(.drawerToggle(name: capsule.name), by: .operatorGesture)
            } label: {
                HStack(spacing: 3) {
                    if capsule.isBadged {
                        Circle().fill(Color.attention).frame(width: 5, height: 5)
                    }
                    Text(capsule.name)
                }
                .foregroundStyle(capsule.isOpen ? Color.textPrimary : Color.textMuted)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    capsule.isOpen ? Color.selection : Color.surfaceRaised, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(capsule.help)
        }
    }
}

/// What a drawer's capsule says, read off the document.
struct DrawerCapsule: Equatable, Identifiable {
    let name: String
    let isOpen: Bool
    let isBadged: Bool

    var id: String { name }

    var help: String {
        (isOpen ? "Hide" : "Show") + " the \(name) drawer"
            + (isBadged ? " — an agent put something here" : "")
    }

    /// Every drawer in the document, in its order. A drawer is never empty (benchd removes it
    /// with its last pane), so each one listed holds something.
    static func of(_ document: BenchDocument?) -> [DrawerCapsule] {
        guard let document else { return [] }
        return document.drawers.map {
            DrawerCapsule(
                name: $0.name, isOpen: $0.name == document.openDrawer, isBadged: $0.badged)
        }
    }
}
