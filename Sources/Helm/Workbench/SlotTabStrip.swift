import HelmWire
import Inject
import SwiftUI

/// One slot's tabs, and the only thing that knows a slot can hold both kinds of pane.
///
/// It is `TerminalStrip` split in two: the terminal-specific tab chrome went to
/// `TerminalTab`, and what is left here is bench chrome. Which of the two a pane gets is
/// the one `switch` in this file, and it is a rendering of `Pane.Content` rather than a
/// decision about it.
///
/// **No decisions.** No `slot.panes.count > 1`, no placement, no close-selects-neighbour.
/// Every one of those is a `Workbench` method. A reviewer can check this file by grepping
/// it for `count`, `first`, `firstIndex` and `isEmpty`.
struct SlotTabStrip: View {
    /// Hot reload: `.enableInjection()` below redraws this view when InjectionNext swaps a
    /// recompiled build of it into the running app. Both are no-ops in release.
    @ObserveInjection private var inject
    @ObservedObject var model: WorkbenchModel
    let slot: Slot
    /// Whether this is the slot commands target. The app chrome — ⌘O's browser and the
    /// appearance menu — appears only here, so N slots do not mean N copies of it.
    let isFocused: Bool
    let workspaceRoot: String?

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(slot.panes) { pane in
                        tab(for: pane)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.send(.focusSlot(slot.id), by: .operatorGesture)
                model.send(.paneOpen(surface: .terminal(agent: nil)), by: .operatorGesture)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textMuted)
            .help("New terminal (⌘N)")

            if isFocused {
                Divider()
                    .frame(height: 14)

                Button {
                    model.isBrowserOpen.toggle()
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.textMuted)
                .help("Open artifact (⌘O)")
                .popover(isPresented: $model.isBrowserOpen, arrowEdge: .bottom) {
                    ArtifactBrowser(workspaceRoot: workspaceRoot) { url in
                        model.send(
                            .paneOpen(surface: .canvas(path: url.path)), by: .operatorGesture)
                    } onDismiss: {
                        model.isBrowserOpen = false
                    }
                }

                // Mirrors View ▸ Appearance; the control itself belongs to App.
                AppearanceMenu()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(Color.textPrimary)
        .background(ChromeBackground())
        .contentShape(Rectangle())
        .onTapGesture { model.send(.focusSlot(slot.id), by: .operatorGesture) }
        .enableInjection()
    }

    /// The kind draws the tab (`SurfaceKind.tab`); the bench says whether it is selected and
    /// whether it can close — the bench's rule, not the slot's: a pane can close unless it is
    /// the bench's last.
    @ViewBuilder
    private func tab(for pane: Pane) -> some View {
        model.surfaceTab(of: pane, in: model.surfaceSlot(for: pane, in: slot))
    }
}
