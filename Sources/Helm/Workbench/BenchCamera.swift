import CoreGraphics

/// Where ⌘J's zoom looks at the bench from: the box the bench is laid out in, and how far the
/// window is panned over it.
///
/// **A camera move, not a resize and not a maximize.** The bench is laid out again in a box
/// larger than the window and the window is panned to the focused slot, so that slot takes most
/// of the window while its neighbours run off the edges at their true proportions. Nothing is
/// hidden and nothing in the document changes: the fractions, the focus and the panes are the
/// same zoomed or not. tuios does the same thing (`internal/app/zoom_canvas.go`), and its reason
/// for laying out again rather than scaling holds here too: a terminal gets more cells rather
/// than bigger text, a divider stays one point, and a divider drag stays 1:1 with the pointer.
///
/// **helm's alone.** How one helm looks at a bench is not a fact about the bench, so the zoom is
/// a `LocalAction` and a flag on `WorkbenchModel`, never a verb: an agent cannot move the
/// operator's view (#125), and a relaunch starts unzoomed.
struct BenchCamera: Equatable {
    /// The box the bench is laid out in. Never smaller than the window on either axis.
    let canvas: CGSize
    /// The top-left of the window over `canvas`. Always inside it: `0...canvas - viewport`.
    let pan: CGPoint

    /// How much of the window the zoomed slot is lifted to take, on each axis it has room on.
    static let share: CGFloat = 0.85
    /// The least a neighbour shows on a side that has one, so a peek is a pane carrying on past
    /// the edge rather than a stray line. Takes precedence over `share` in a small window.
    static let peek: CGFloat = 48

    /// No zoom: the bench at the window's own size.
    static func identity(_ viewport: CGSize) -> BenchCamera {
        BenchCamera(canvas: viewport, pan: .zero)
    }

    /// The camera on the bench's focused slot.
    ///
    /// **One factor per axis.** A slot that already spans an axis — a column with one slot is
    /// the whole height — has nothing to gain on it, and growing the box there would push the
    /// slot's own ends off the window. Each axis is floored at the window, so the lift happens
    /// only where there is room for it, and a bench of one slot is the identity.
    static func framing(_ bench: Workbench, in viewport: CGSize) -> BenchCamera {
        guard viewport.width > 0, viewport.height > 0,
            let unit = focusedRect(of: bench, in: viewport)
        else { return .identity(viewport) }
        let canvas = CGSize(
            width: lifted(viewport.width, tile: unit.width),
            height: lifted(viewport.height, tile: unit.height))
        // Laid out again at the canvas's size, so the slot is found with the same arithmetic
        // that will draw it, dividers and all.
        guard let slot = focusedRect(of: bench, in: canvas) else { return .identity(viewport) }
        return BenchCamera(
            canvas: canvas,
            pan: CGPoint(
                x: centred(slot.midX, viewport: viewport.width, canvas: canvas.width),
                y: centred(slot.midY, viewport: viewport.height, canvas: canvas.height)))
    }

    /// The canvas extent on one axis that lifts a `tile`-sized slot to its share of `viewport`.
    private static func lifted(_ viewport: CGFloat, tile: CGFloat) -> CGFloat {
        let want = min(viewport * share, viewport - 2 * peek)
        guard tile > 0, want > tile else { return viewport }
        return (viewport * want / tile).rounded()
    }

    /// The pan that centres `mid`, held inside the canvas: a slot at the bench's edge sits
    /// flush with the window's rather than showing empty canvas beyond it.
    private static func centred(_ mid: CGFloat, viewport: CGFloat, canvas: CGFloat) -> CGFloat {
        min(max(mid - viewport / 2, 0), canvas - viewport)
    }

    /// The focused slot's rectangle when the bench is laid out in `size`, by `SplitLayout` —
    /// the arithmetic `WorkbenchView` draws with. The minimum extents do not enter into it:
    /// they bound a drag, not a layout.
    private static func focusedRect(of bench: Workbench, in size: CGSize) -> CGRect? {
        let across = SplitLayout(
            extent: size.width, memberCount: bench.columns.count, minimumExtent: 0)
        var x: CGFloat = 0
        for column in bench.columns {
            let width = across.points(column.width)
            let down = SplitLayout(
                extent: size.height, memberCount: column.slots.count, minimumExtent: 0)
            var y: CGFloat = 0
            for slot in column.slots {
                let height = down.points(slot.height)
                if slot.id == bench.focusedSlot {
                    return CGRect(x: x, y: y, width: width, height: height)
                }
                y += height + SplitLayout.dividerThickness
            }
            x += width + SplitLayout.dividerThickness
        }
        return nil
    }
}
