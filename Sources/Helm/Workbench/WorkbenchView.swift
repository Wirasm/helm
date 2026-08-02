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
struct WorkbenchView: View {
    @ObserveInjection private var inject
    @ObservedObject var model: WorkbenchModel
    let workspaceRoot: String?

    var body: some View {
        Group {
            if let bench = model.bench {
                // The bench's own width, so a column can turn its fraction into points
                // and a dragged size back into a fraction.
                GeometryReader { geo in
                    HSplitView {
                        ForEach(bench.columns) { column in
                            ColumnView(
                                model: model, bench: bench, column: column,
                                benchWidth: geo.size.width, workspaceRoot: workspaceRoot)
                        }
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
    let benchWidth: CGFloat
    let workspaceRoot: String?

    /// The column's own height, so its slots can do the same arithmetic one level down.
    @State private var height: CGFloat = 0
    /// The stored fraction, in points, captured **once**. See `seed`.
    @State private var seeded: CGFloat?

    var body: some View {
        VSplitView {
            ForEach(column.slots) { slot in
                SlotView(
                    model: model, bench: bench, slot: slot, columnHeight: height,
                    workspaceRoot: workspaceRoot)
            }
        }
        // `HSplitView` exposes exactly one member — `init(content:)`. No divider API, no
        // `autosaveName`, no binding, verified against the macOS 26.2 SDK interface. So a
        // size is seeded through `idealWidth` and read back through a GeometryReader,
        // which is what `CanvasDock` already did at N=1.
        .frame(minWidth: 240, idealWidth: seeded, maxWidth: .infinity, maxHeight: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        seed()
                        height = geo.size.height
                    }
                    .onChange(of: geo.size) { _, size in
                        height = size.height
                        report(size.width)
                    }
            }
        )
        .enableInjection()
    }

    /// **Seeded once and never re-read.** `idealWidth` deliberately does not track
    /// `column.width`: if it did, the write-back below would change the value that drives
    /// the layout that produced it, and the two would chase each other every frame. Seeding
    /// at mount is all restore needs — after that the divider is the operator's.
    private func seed() {
        guard seeded == nil, benchWidth > 0 else { return }
        seeded = benchWidth * column.width
    }

    /// Write a dragged size back as a fraction.
    ///
    /// **Dead-banded, and deliberately not a `PreferenceKey`.** `stevengharris/SplitView`
    /// dropped its `HSplitView` dependency because `GeometryReader` + `PreferenceKey`
    /// inside *nested* split views produced intermittent "Bound preference … tried to
    /// update multiple times per frame". `.onChange(of:)` is not that mechanism, and the
    /// sub-point dead band keeps a rounding difference from writing on every frame.
    private func report(_ width: CGFloat) {
        guard benchWidth > 1 else { return }
        let fraction = width / benchWidth
        guard abs(fraction - column.width) * benchWidth >= 1 else { return }
        model.resizeColumn(column.id, to: fraction)
    }
}

// MARK: - Slot

private struct SlotView: View {
    @ObserveInjection private var inject
    @ObservedObject var model: WorkbenchModel
    let bench: Workbench
    let slot: Slot
    let columnHeight: CGFloat
    let workspaceRoot: String?

    @State private var seeded: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            SlotTabStrip(
                model: model, slot: slot, isFocused: slot.id == bench.focusedSlot,
                workspaceRoot: workspaceRoot)
            Divider()
            content
        }
        .frame(minHeight: 80, idealHeight: seeded, maxHeight: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear(perform: seed)
                    .onChange(of: geo.size.height) { _, height in report(height) }
            }
        )
        .enableInjection()
    }

    private func seed() {
        guard seeded == nil, columnHeight > 0 else { return }
        seeded = columnHeight * slot.height
    }

    private func report(_ height: CGFloat) {
        guard columnHeight > 1 else { return }
        let fraction = height / columnHeight
        guard abs(fraction - slot.height) * columnHeight >= 1 else { return }
        model.resizeSlot(slot.id, to: fraction)
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
            CanvasView(model: model.canvas(for: pane))
        }
    }
}
