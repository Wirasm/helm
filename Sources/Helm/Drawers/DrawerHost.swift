import HelmWire
import SwiftUI

/// The drawer shown over the bench (#356), drawn from benchd's document.
///
/// **An overlay, never a column.** `RootView` puts it over the bench and the rail rather than
/// beside them, so opening one changes no column's width, no slot's height and no pane on
/// screen: the layout under it is the one the document describes, drawn by `WorkbenchView`
/// exactly as it was. The empty side of the overlay draws nothing and so takes no clicks; the
/// bench beside the drawer stays usable.
///
/// Which drawer is open, what it holds and which of its panes is showing are the document's.
/// Where it sits and how wide it is are helm's: `[drawer.<name>]` in the keymap file, else
/// `DrawerStyle.builtIn(for:)`.
struct DrawerHost: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var keymap: Keymap

    var body: some View {
        GeometryReader { geo in
            if let drawer = model.openDrawer {
                let style = keymap.style(for: drawer.name)
                DrawerPanel(model: model, drawer: drawer, edge: style.edge)
                    .frame(width: geo.size.width * style.size)
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity,
                        alignment: style.edge == .left ? .leading : .trailing
                    )
                    .transition(.move(edge: style.edge == .left ? .leading : .trailing))
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.openDrawer?.name)
    }
}

/// One drawer: a header with its name, its tabs when it holds more than one pane, and the
/// button that hides it; then the selected pane, drawn by its kind like any bench pane.
private struct DrawerPanel: View {
    @ObservedObject var model: WorkbenchModel
    let drawer: BenchDocument.Drawer
    let edge: DrawerStyle.Edge

    private var panes: [Pane] {
        drawer.panes.map { Pane(id: $0.id, content: .init($0.surface), name: $0.name) }
    }

    var body: some View {
        HStack(spacing: 0) {
            if edge == .right { Color.border.frame(width: 1) }
            VStack(spacing: 0) {
                header
                Color.border.frame(height: 1)
                content
            }
            if edge == .left { Color.border.frame(width: 1) }
        }
        .background(Color.surface)
        .shadow(color: .black.opacity(0.25), radius: 8)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(drawer.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.textMuted)
            if panes.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(panes) { pane in
                            model.surfaceTab(of: pane, in: slot(for: pane))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                model.send(.drawerToggle(name: drawer.name), by: .operatorGesture)
            } label: {
                Image(systemName: edge == .left ? "sidebar.left" : "sidebar.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textMuted)
            .help("Hide the \(drawer.name) drawer")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.surfaceRaised)
    }

    @ViewBuilder
    private var content: some View {
        if let pane = panes.first(where: { $0.id == drawer.selected }) {
            Group {
                if let view = model.surfaceView(of: pane, in: slot(for: pane)) {
                    view
                } else {
                    // A kind that cannot be made here: a terminal, which has no workspace to
                    // start in inside a drawer.
                    Text("A \(pane.content.kind.rawValue) cannot be shown in a drawer yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // The stable pane id, for `SlotView`'s reason: a changing id replaces the view.
            .id(pane.id)
        }
    }

    /// The drawer's answers to what a surface asks. Its selected pane has the keyboard while
    /// the drawer is shown, which is what the bench's focused pane gives up (`surfaceSlot`).
    private func slot(for pane: Pane) -> SurfaceSlot {
        SurfaceSlot(
            pane: pane,
            holdsKeyboard: pane.id == drawer.selected,
            isSelected: pane.id == drawer.selected,
            canClose: true,
            select: { model.send(.paneShow(pane.id), by: .operatorGesture) },
            close: { model.send(.paneClose(pane.id), by: .operatorGesture) })
    }
}
