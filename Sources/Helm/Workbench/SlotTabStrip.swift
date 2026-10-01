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
                Image(systemName: "plus").frame(width: 18, height: 18)
            }
            .buttonStyle(.chrome)
            .foregroundStyle(Color.textMuted)
            .help("New terminal (⌘N)")

            if isFocused {
                Divider()
                    .frame(height: 14)

                Button {
                    model.isBrowserOpen.toggle()
                } label: {
                    Image(systemName: "doc.text").frame(width: 18, height: 18)
                }
                .buttonStyle(.chrome)
                .foregroundStyle(Color.textMuted)
                .help("Open artifact (⌘O)")
                .popover(isPresented: $model.isBrowserOpen, arrowEdge: .bottom) {
                    ArtifactBrowser(
                        workspaceRoot: workspaceRoot, prp: PrpStores(client: model.client)
                    ) { url in
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
        // Where the strip is, for a tab dropped into one of its gaps (`PaneDrop`).
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(PaneDrop.space))
        } action: {
            model.paneDrag.frames[slot.id, default: SlotFrames()].strip = $0
        }
        .enableInjection()
    }

    /// The kind draws the tab (`SurfaceKind.tab`); the bench says whether it is selected and
    /// whether it can close — the bench's rule, not the slot's: a pane can close unless it is
    /// the bench's last.
    ///
    /// Every tab can be dragged to another place on the bench (#178, `PaneDrop`): the gesture
    /// reports the pointer in `PaneDrop.space` and the release becomes one `pane/move`. Four
    /// points of travel before it starts, so a click on a tab stays a click. Simultaneous, so
    /// the tab's own tap does not hold it back.
    @ViewBuilder
    private func tab(for pane: Pane) -> some View {
        if let tab = model.surfaceTab(of: pane, in: model.surfaceSlot(for: pane, in: slot)) {
            draggable(tab, pane: pane.id)
        }
    }

    private func draggable(_ tab: AnyView, pane: Pane.ID) -> some View {
        tab
            .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(PaneDrop.space))
                    .onChanged { model.dragPane(pane, to: $0.location) }
                    .onEnded { model.dropPane(pane, at: $0.location) }
            )
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(PaneDrop.space))
            } action: {
                model.paneDrag.frames[slot.id, default: SlotFrames()].tabs[pane] = $0
            }
            // A document that arrives mid-drag can take this tab off the screen, and then no
            // end comes for its gesture: without this the drop zone would stay drawn.
            .onDisappear { model.paneDrag.cancel(pane) }
    }
}
