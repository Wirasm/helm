import HelmWire
import SwiftUI

/// Dragging a tab to another place on the bench (#178).
///
/// **helm decides which place the pointer means; benchd decides what a move there does.** The
/// first is geometry over frames helm drew, so it is resolved here, as a value, by
/// `PaneDrop.resolve`. The second is `pane/move` with a `tab` or `beside` destination, sent
/// as the operator's gesture like a key or a divider drag, and drawn when the document comes
/// back. Nothing here changes a bench.
///
/// The drag is a `DragGesture`, as `SplitStack`'s dividers are, rather than a pasteboard drag:
/// the pane bodies are a Ghostty view and a web view that take pasteboard drags themselves (a
/// terminal pastes a dropped string), and a gesture in a named space hands the point over
/// directly.
enum PaneDrop {
    /// The space every frame and every pointer location here is measured in: the bench's
    /// viewport, which a drag cannot move (`SplitStack`'s gesture says what a moving one cost).
    static let space = "helm.pane-drop"

    /// How deep, as a share of the slot, the band on each edge that splits rather than tabs.
    static let edgeBand: CGFloat = 0.25

    /// What the pointer at `point` would do with `pane`: a destination for `pane/move` and
    /// the drop zone that shows it. nil off the bench and wherever the drop would leave the pane
    /// where it is — a zone there would promise a move that does not happen.
    ///
    /// Those no-ops are benchd's rules (`move_pane_to_tab`, `move_pane_beside`), read here only
    /// to decide whether to draw. benchd stays the authority: it answers a no-op it is sent with
    /// `changed: false`.
    static func resolve(
        pane: Pane.ID, at point: CGPoint, bench: Workbench, frames: [Slot.ID: SlotFrames]
    ) -> PaneDropTarget? {
        for column in bench.columns {
            for slot in column.slots {
                guard let drawn = frames[slot.id], drawn.body.contains(point) else { continue }
                let place = Place(pane: pane, slot: slot, column: column, drawn: drawn)
                if drawn.strip.contains(point) { return place.tab(at: point.x) }
                return place.body(at: point, columnFrame: columnFrame(column, frames))
            }
        }
        return nil
    }

    private static func columnFrame(_ column: Column, _ frames: [Slot.ID: SlotFrames]) -> CGRect {
        column.slots.compactMap { frames[$0.id]?.body }.reduce(CGRect.null) { $0.union($1) }
    }

    /// One slot under the pointer, and the dragged pane's standing in it.
    private struct Place {
        let pane: Pane.ID
        let slot: Slot
        let column: Column
        let drawn: SlotFrames

        private var isOwn: Bool { slot.panes.contains { $0.id == pane } }

        /// Over the tab strip: the gap before the first tab whose middle is right of the pointer.
        func tab(at x: CGFloat) -> PaneDropTarget? {
            let tabs = slot.panes.compactMap { p in drawn.tabs[p.id].map { (id: p.id, frame: $0) } }
            let before = tabs.first { $0.frame.midX > x }
            guard !isNoOpTab(before: before?.id) else { return nil }
            let seamX =
                before.map { $0.frame.minX - 2 } ?? (tabs.last?.frame.maxX ?? drawn.strip.minX) + 2
            return PaneDropTarget(
                move: .tab(slot: slot.id, before: before?.id), preview: drawn.body,
                seam: CGRect(
                    x: seamX - 1, y: drawn.strip.minY + 3, width: 2,
                    height: max(drawn.strip.height - 6, 0)))
        }

        /// Over the body: an edge band splits beside the slot, the middle joins it as a tab.
        func body(at point: CGPoint, columnFrame: CGRect) -> PaneDropTarget? {
            let b = drawn.body
            let u = (point.x - b.minX) / max(b.width, 1)
            let v = (point.y - b.minY) / max(b.height, 1)
            let edges: [(BenchDirection, CGFloat)] = [
                (.left, u), (.right, 1 - u), (.up, v), (.down, 1 - v),
            ]
            guard let (side, depth) = edges.min(by: { $0.1 < $1.1 }), depth < PaneDrop.edgeBand
            else { return middle() }
            return beside(side, columnFrame: columnFrame)
        }

        /// The middle of a slot is "as its last tab". Its own slot's middle is nowhere: dropping
        /// a tab back onto the body it came from should not reorder it.
        private func middle() -> PaneDropTarget? {
            guard !isOwn else { return nil }
            let end = slot.panes.compactMap { drawn.tabs[$0.id]?.maxX }.max() ?? drawn.strip.minX
            return PaneDropTarget(
                move: .tab(slot: slot.id, before: nil), preview: drawn.body,
                seam: CGRect(
                    x: end + 1, y: drawn.strip.minY + 3, width: 2,
                    height: max(drawn.strip.height - 6, 0)))
        }

        private func beside(_ side: BenchDirection, columnFrame: CGRect) -> PaneDropTarget? {
            let vertical = side == .up || side == .down
            if isOwn && slot.panes.count == 1 && (vertical || column.slots.count == 1) {
                return nil
            }
            let region = vertical ? drawn.body : columnFrame
            let preview = region.half(side)
            return PaneDropTarget(
                move: .beside(slot: slot.id, side: side), preview: preview,
                seam: preview.edgeBar(side, thickness: 3))
        }

        /// Before itself, or before the tab already after it, is where it is.
        private func isNoOpTab(before: Pane.ID?) -> Bool {
            guard let index = slot.panes.firstIndex(where: { $0.id == pane }) else { return false }
            let next = slot.panes.indices.contains(index + 1) ? slot.panes[index + 1].id : nil
            return before == pane || before == next
        }
    }
}

/// Where a drop would go, and the drop zone that says so: `preview` is the region the pane will
/// occupy and `seam` the bar where it enters — the edge it splits, or the gap in a tab strip.
struct PaneDropTarget: Equatable {
    let move: BenchMoveTo
    let preview: CGRect
    let seam: CGRect
}

/// Where one slot is drawn, in `PaneDrop.space`: the whole slot, its tab strip, and each tab.
struct SlotFrames: Equatable {
    var body: CGRect = .null
    var strip: CGRect = .null
    var tabs: [Pane.ID: CGRect] = [:]
}

extension CGRect {
    fileprivate func half(_ side: BenchDirection) -> CGRect {
        switch side {
        case .left: CGRect(x: minX, y: minY, width: width / 2, height: height)
        case .right: CGRect(x: midX, y: minY, width: width / 2, height: height)
        case .up: CGRect(x: minX, y: minY, width: width, height: height / 2)
        case .down: CGRect(x: minX, y: midY, width: width, height: height / 2)
        }
    }

    fileprivate func edgeBar(_ side: BenchDirection, thickness t: CGFloat) -> CGRect {
        switch side {
        case .left: CGRect(x: minX, y: minY, width: t, height: height)
        case .right: CGRect(x: maxX - t, y: minY, width: t, height: height)
        case .up: CGRect(x: minX, y: minY, width: width, height: t)
        case .down: CGRect(x: minX, y: maxY - t, width: width, height: t)
        }
    }
}

// MARK: - The live drag

/// The drag in progress and the frames it is resolved against. Its own object so that only the
/// drop-zone overlay redraws as the pointer moves; the frames are not published at all, because
/// every layout reports them and a redraw per report would be a redraw per frame.
@MainActor
final class PaneDragModel: ObservableObject {
    var frames: [Slot.ID: SlotFrames] = [:]
    /// The pane being dragged and what the pointer is over. nil between drags.
    @Published private(set) var drag: (pane: Pane.ID, target: PaneDropTarget?)?

    func update(_ pane: Pane.ID, target: PaneDropTarget?) {
        drag = (pane, target)
    }

    /// Ends the drag, answering where it was dropped.
    func end() -> PaneDropTarget? {
        defer { drag = nil }
        return drag?.target
    }

    /// The tab being dragged left the screen mid-drag, so no end will come for it.
    func cancel(_ pane: Pane.ID) {
        if drag?.pane == pane { drag = nil }
    }
}

extension WorkbenchModel {
    /// The pointer moved with `pane`'s tab held, at `point` in `PaneDrop.space`.
    func dragPane(_ pane: Pane.ID, to point: CGPoint) {
        guard let bench else { return }
        paneDrag.update(
            pane,
            target: PaneDrop.resolve(pane: pane, at: point, bench: bench, frames: paneDrag.frames))
    }

    /// `pane`'s tab was released at `point`: one `pane/move` there, as the operator's gesture,
    /// or nothing where the drop would change nothing.
    func dropPane(_ pane: Pane.ID, at point: CGPoint) {
        dragPane(pane, to: point)
        guard let target = paneDrag.end() else { return }
        send(.paneMove(pane, target.move), by: .operatorGesture)
    }
}
