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
                model.focus(slot.id)
                model.newTerminal()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New terminal (⌘N)")

            faceToggle

            if isFocused {
                Divider()
                    .frame(height: 14)

                Button {
                    model.isBrowserOpen.toggle()
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open artifact (⌘O)")
                .popover(isPresented: $model.isBrowserOpen, arrowEdge: .bottom) {
                    ArtifactBrowser(workspaceRoot: workspaceRoot) { url in
                        model.open(.file(url))
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
        .onTapGesture { model.focus(slot.id) }
        .enableInjection()
    }

    @ViewBuilder
    private func tab(for pane: Pane) -> some View {
        let isSelected = pane.id == slot.selected
        // `canClose` is the BENCH's rule — a pane can close unless it is the bench's last,
        // not unless it is the slot's last.
        let canClose = model.bench?.canClose(pane.id) ?? false
        switch pane.content {
        case .terminal:
            if let session = model.session(for: pane) {
                TerminalTab(
                    session: session,
                    isSelected: isSelected,
                    canClose: canClose,
                    onSelect: { model.select(pane.id) },
                    onClose: { model.close(pane.id) }
                )
            }
        case let .canvas(source):
            CanvasTab(
                source: source,
                isSelected: isSelected,
                canClose: canClose,
                onSelect: { model.select(pane.id) },
                onClose: { model.close(pane.id) }
            )
        }
    }

    /// The two faces of this slot's selected pane. Same terminal underneath either way.
    ///
    /// **Always present, always pressable** — deliberately not gated on whether an agent
    /// is running. The foreground pid moves constantly beneath it (`shell` was measured at
    /// 947 consecutive samples), so a control that tracked it would flicker between
    /// enabled and disabled while nothing about the operator's intent changed. Under a
    /// bench the temptation gets stronger — N strips, N flickers — and the answer is the
    /// same. Pressing it with no agent is not an error: the face itself names the reason.
    ///
    /// Absent entirely when the slot is showing a canvas, because `face(ofSelectedPaneIn:)`
    /// answers nil for one. `if let` on a value the model computed is rendering; asking
    /// what kind of pane it is would be a decision, and that lives in `Workbench`.
    @ViewBuilder
    private var faceToggle: some View {
        if let face = model.bench?.face(ofSelectedPaneIn: slot.id) {
            Divider()
                .frame(height: 14)

            Button {
                model.focus(slot.id)
                model.toggleFace()
            } label: {
                Image(systemName: face == .chat ? "terminal" : "text.alignleft")
            }
            .buttonStyle(.plain)
            .foregroundStyle(face == .chat ? Color.accent : .secondary)
            .help(face == .chat ? "Back to the terminal (⌘T)" : "Read the agent's writing (⌘T)")
            .accessibilityLabel(face == .chat ? "Show the terminal" : "Read the agent's writing")
        }
    }
}
