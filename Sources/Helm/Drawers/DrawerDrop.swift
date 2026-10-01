import SwiftUI

/// Dragging an open drawer to another edge of the window (#178).
///
/// **helm decides which edge the pointer means; benchd keeps it.** The first is geometry over
/// the area the drawer is drawn in, resolved here as a value. The second is `drawer/place`, sent
/// as the operator's gesture through `WorkbenchModel.dropTab` like every other drop, and drawn
/// when the document comes back (`DrawerStyle.placed(_:by:)`).
///
/// The drag is the drawer header's `DragGesture`, in `BenchDrag.space`, so it shares the drop
/// zone, the Escape that cancels it and the one door with the bench's own drags.
enum DrawerDrop {
    /// How far in from an edge, as a share of the area, the pointer still means that edge.
    static let reach: CGFloat = 0.3

    /// What the pointer at `point` would do with the drawer `frame` describes: the edge it would
    /// move to and the drop zone that shows it. nil away from every edge and over the edge the
    /// drawer is already on, where a zone would promise a move that does not happen.
    static func resolve(at point: CGPoint, frame: DrawerFrame) -> DropTarget? {
        let area = frame.area
        guard !area.isEmpty else { return nil }
        let u = (point.x - area.minX) / area.width
        let v = (point.y - area.minY) / area.height
        let edges: [(DrawerStyle.Edge, CGFloat)] = [(.left, u), (.right, 1 - u), (.bottom, 1 - v)]
        guard let (edge, depth) = edges.min(by: { $0.1 < $1.1 }), depth < reach,
            edge != frame.style.edge
        else { return nil }
        return DropTarget(
            to: .drawerEdge(edge), preview: area.band(edge, share: frame.style.size),
            seam: area.band(edge, thickness: 3))
    }
}

/// The open drawer, as `DrawerHost` draws it: its style and the area it is drawn over, in
/// `BenchDrag.space`. Only an open drawer's header can be dragged, so it is the one this is.
struct DrawerFrame: Equatable {
    let area: CGRect
    let style: DrawerStyle
}

extension CGRect {
    /// The band along `edge` a drawer of `share` of the window occupies.
    fileprivate func band(_ edge: DrawerStyle.Edge, share: Double) -> CGRect {
        band(edge, thickness: (edge == .bottom ? height : width) * share)
    }

    fileprivate func band(_ edge: DrawerStyle.Edge, thickness t: CGFloat) -> CGRect {
        switch edge {
        case .left: CGRect(x: minX, y: minY, width: t, height: height)
        case .right: CGRect(x: maxX - t, y: minY, width: t, height: height)
        case .bottom: CGRect(x: minX, y: maxY - t, width: width, height: t)
        }
    }
}
