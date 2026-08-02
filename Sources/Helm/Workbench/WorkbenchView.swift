import Inject
import SwiftUI

/// The bench on screen: columns side by side, slots stacked inside them.
///
/// **Rendering, and only rendering.** No `if slot.panes.count > 1`, no placement, no
/// close-selects-neighbour — every one of those is a `Workbench` method, which is the
/// whole point of building the bench as a value first. Three times in two days the real
/// defect in this codebase was logic trapped in a `View` where no test could reach it;
/// this file is the answer to that, and stays worth checking by grepping it for `count`,
/// `first`, `firstIndex` and `isEmpty`.
///
/// The sizes are `SplitStack`'s, and computed from the bench rather than measured off the
/// screen — see that file for what measuring cost (#90).
struct WorkbenchView: View {
    @ObserveInjection private var inject
    @ObservedObject var model: WorkbenchModel
    let workspaceRoot: String?

    /// The smallest a column may be dragged to, and a slot below it. Held here rather than
    /// in `SplitStack` because they are this bench's judgement about its own tenants: a
    /// terminal narrower than this has nothing readable in it, and a slot shorter than this
    /// has lost its tab strip.
    static let minimumColumnWidth: CGFloat = 240
    static let minimumSlotHeight: CGFloat = 80

    var body: some View {
        Group {
            if let bench = model.bench {
                // The bench's own size, so a column can turn its fraction into points and
                // a slot can do the same one level down. The only measurement left in the
                // file, and it drives the layout rather than being written back into it.
                GeometryReader { geo in
                    SplitStack(
                        axis: .horizontal, extent: geo.size.width, members: bench.columns,
                        fraction: { $0.width }, minimumExtent: Self.minimumColumnWidth,
                        resize: { model.resizeColumn($0, to: $1, against: $2) }
                    ) { column in
                        ColumnView(
                            model: model, bench: bench, column: column, height: geo.size.height,
                            workspaceRoot: workspaceRoot)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                // No workspace open, so there is no bench — `Workbench`'s first invariant
                // is that a bench always holds a pane, so this is nil rather than empty.
                ContentUnavailableView(
                    "Open a workspace", systemImage: "folder",
                    description: Text("Choose a folder with ⌘⇧O to start a terminal."))
            }
        }
        .enableInjection()
    }
}

// MARK: - Column

private struct ColumnView: View {
    @ObserveInjection private var inject
    @ObservedObject var model: WorkbenchModel
    let bench: Workbench
    let column: Column
    /// The bench's height, which is the column's — columns span it. Handed down rather
    /// than measured, so a slot's height is known at the first layout instead of after one.
    let height: CGFloat
    let workspaceRoot: String?

    var body: some View {
        SplitStack(
            axis: .vertical, extent: height, members: column.slots,
            fraction: { $0.height }, minimumExtent: WorkbenchView.minimumSlotHeight,
            resize: { model.resizeSlot($0, to: $1, against: $2) }
        ) { slot in
            SlotView(
                model: model, bench: bench, slot: slot, workspaceRoot: workspaceRoot)
        }
        .enableInjection()
    }
}

// MARK: - Slot

private struct SlotView: View {
    @ObserveInjection private var inject
    @ObservedObject var model: WorkbenchModel
    let bench: Workbench
    let slot: Slot
    let workspaceRoot: String?

    var body: some View {
        VStack(spacing: 0) {
            SlotTabStrip(
                model: model, slot: slot, isFocused: slot.id == bench.focusedSlot,
                workspaceRoot: workspaceRoot)
            // A palette hairline rather than `Divider()`: a system separator is one more
            // colour from one more source, which is the thing the palette exists to end.
            Color.border.frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .enableInjection()
    }

    @ViewBuilder
    private var content: some View {
        if let pane = slot.panes.first(where: { $0.id == slot.selected }) {
            paneContent(pane)
                // Mandatory, and it must be the stable pane id and nothing else. An
                // NSViewRepresentable can never swap its NSView instance in place, and a
                // CHANGING `.id()` does not update a view — it replaces it, which re-runs
                // `makeNSView` and kills the pty. Never derive this from an index, a
                // title or a generation.
                .id(pane.id)
        }
    }

    @ViewBuilder
    private func paneContent(_ pane: Pane) -> some View {
        switch pane.content {
        case let .terminal(face):
            if let session = model.session(for: pane) {
                TerminalPaneView(session: session, face: face)
            }
        case .canvas:
            CanvasView(model: model.canvas(for: pane), post: postHandler)
        }
    }

    /// nil when there is nowhere unambiguous to send notes, which is what leaves the
    /// canvas's `Post` disabled with a reason rather than silently doing nothing.
    private var postHandler: ((String) -> Void)? {
        guard model.composeTarget != nil else { return nil }
        return { model.post($0) }
    }
}
