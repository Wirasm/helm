import HelmWire
import SwiftUI

/// What a drop on the workspace bar means (#178): a workspace tab dropped in a gap reorders the
/// bar (`workspace/move`), and a pane's tab dropped on another workspace's tab moves the pane
/// there (`pane/move {to: {workspace}}`). The bench's own drops are `PaneDrop`'s.
///
/// Pure, like `PaneDrop.resolve`: geometry over the frames the bar reported, so tests reach it
/// without a window. benchd decides what the move does.
enum WorkspaceDrop {
    /// What the pointer at `point`, over the bar, would do with `item`. nil wherever the drop
    /// would change nothing or benchd would refuse it: a workspace in its own place, a pane over
    /// its own workspace or a gap, a pane its bench cannot give up (a workspace's last pane), a
    /// pane whose surface the target already shows, a workspace anywhere but the bar, and files.
    ///
    /// The bar draws its tabs in the document's order, so that is the order read here.
    static func resolve(
        _ item: DragItem, at point: CGPoint, document: BenchDocument, frames: BarFrames
    ) -> DropTarget? {
        let tabs = document.workspaces.compactMap { workspace in
            frames.tabs[WorkspacePath(workspace.path)].map { (workspace: workspace, frame: $0) }
        }
        switch item {
        case let .workspace(path):
            let order = tabs.map { (path: WorkspacePath($0.workspace.path), frame: $0.frame) }
            return gap(for: path, at: point.x, tabs: order, strip: frames.strip)
        case let .pane(pane):
            guard let over = tabs.first(where: { $0.frame.contains(point) }),
                let from = document.workspaces.first(where: { $0.path == document.active }),
                over.workspace.path != from.path, from.bench.panes.count > 1,
                let surface = from.bench.panes.first(where: { $0.id == pane })?.surface,
                !over.workspace.bench.panes.contains(where: { $0.surface.alreadyShows(surface) })
            else { return nil }
            return DropTarget(to: .workspace(over.workspace.path), preview: over.frame)
        case .files:
            // Files open on a bench, at a place on it (`FileDrop`); the bar is not one.
            return nil
        }
    }

    /// The gap before the first tab whose middle is right of the pointer, else the end.
    private static func gap(
        for path: WorkspacePath, at x: CGFloat, tabs: [(path: WorkspacePath, frame: CGRect)],
        strip: CGRect
    ) -> DropTarget? {
        guard let index = tabs.firstIndex(where: { $0.path == path }) else { return nil }
        let before = tabs.first { $0.frame.midX > x }
        let next = tabs.indices.contains(index + 1) ? tabs[index + 1].path : nil
        if before?.path == path || before?.path == next { return nil }
        let seamX = before.map { $0.frame.minX - 2 } ?? (tabs.last?.frame.maxX ?? strip.minX) + 2
        let height = tabs.first?.frame.height ?? strip.height
        let top = tabs.first?.frame.minY ?? strip.minY
        return DropTarget(
            to: .bar(before: before?.path.value), preview: strip,
            seam: CGRect(x: seamX - 1, y: top + 2, width: 2, height: max(height - 4, 0)))
    }
}

/// Where the workspace bar is drawn, in `BenchDrag.space`: the whole strip and each tab.
struct BarFrames: Equatable {
    var strip: CGRect = .null
    var tabs: [WorkspacePath: CGRect] = [:]
}
