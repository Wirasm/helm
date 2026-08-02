import AppKit
import SwiftUI

// MARK: - SplitLayout

/// The arithmetic of one split stack, as a value: a member's fraction in points, and a
/// dragged divider back as a fraction.
///
/// Separate from the view because #90 was geometry logic living where no test could reach
/// it — the bench's restored widths reached the screen through a framework channel nobody
/// could assert on, and did not arrive. Here "a relaunch keeps the operator's layout" is
/// `points(_:)` returning what it was given, which is a unit test.
struct SplitLayout: Equatable {
    /// What one divider takes out of the stack. One point: the bench's panes butt up
    /// against each other, and a gutter would be a visual change this has no business
    /// making. The area you can *grab* is wider, and is the divider's overlay, not its
    /// layout.
    static let dividerThickness: CGFloat = 1

    /// The stack's full extent along its axis.
    let extent: CGFloat
    let members: Int
    /// The smallest a member may be **dragged** to.
    ///
    /// It was `HSplitView`'s `minWidth` to enforce at every layout; helm enforces it where
    /// the operator can feel it. A window resized below `members × minimumExtent` therefore
    /// scales the fractions down rather than overflowing, which is the better of the two
    /// behaviours and the only one that keeps the fractions meaning what they say.
    let minimumExtent: CGFloat

    /// What the members have to share, once the dividers have taken theirs.
    var available: CGFloat {
        max(extent - Self.dividerThickness * CGFloat(max(members - 1, 0)), 0)
    }

    /// A stored fraction, in points. **The whole restore path** — computed, never measured.
    func points(_ fraction: Double) -> CGFloat { max(available * fraction, 0) }

    /// The fraction a member takes when the divider on its far side has been dragged
    /// `translation` points.
    ///
    /// `start` and `neighbour` are the pair's fractions **when the drag began**, not now: a
    /// drag reports translation from where it started, so applying it to the live fractions
    /// would compound it every frame.
    ///
    /// Clamped so neither side can be squeezed away — to `minimumExtent` where the pair is
    /// big enough for both sides to have it, and to half the pair where it is not, which
    /// leaves a sliver you can grab again rather than a pane you cannot get back.
    func dragged(from start: Double, against neighbour: Double, by translation: CGFloat) -> Double {
        guard available > 0 else { return start }
        let pair = max(start, 0) + max(neighbour, 0)
        let least = min(Double(minimumExtent / available), pair / 2)
        return min(max(start + Double(translation / available), least), pair - least)
    }
}

// MARK: - SplitStack

/// N members along one axis at explicit fractions, with a divider helm owns between each
/// pair.
///
/// **helm lays the bench out itself, and has to.** `HSplitView` exposes exactly one member,
/// `init(content:)` — no divider API, no `autosaveName`, no position binding — and it also
/// **ignores `idealWidth`**, which is the channel the bench used to hand its restored
/// fractions to it through. Measured against the macOS 26.2 SDK: three members of a 900pt
/// split asking for 0.55 / 0.30 / 0.15 were laid out 299 / 300 / 299, identically whether
/// the ideal was there before the first layout or arrived after it. The one size it honours
/// is a hard `.frame(width:)`, which makes its own divider inert — so it can carry helm's
/// geometry in neither direction.
///
/// That was #90: the even split it produced was measured by a `GeometryReader` and written
/// back into the model as though the operator had dragged it there, so no bench geometry
/// ever survived a quit. Here a member's size is **computed, never measured**, and nothing
/// but a drag writes a fraction — there is no mount-time measurement left to mistake for an
/// intention.
struct SplitStack<Member: Identifiable, Content: View>: View {
    let axis: Axis
    /// The stack's full extent along `axis`, from the one `GeometryReader` above it.
    let extent: CGFloat
    let members: [Member]
    let fraction: (Member) -> Double
    let minimumExtent: CGFloat
    /// A divider moved: `id` now takes this fraction of the stack, and `neighbour` — the
    /// member on the divider's other side — absorbs exactly the difference.
    let resize: (_ id: Member.ID, _ fraction: Double, _ neighbour: Member.ID) -> Void
    @ViewBuilder let content: (Member) -> Content

    private var layout: SplitLayout {
        SplitLayout(extent: extent, members: members.count, minimumExtent: minimumExtent)
    }

    var body: some View {
        stack {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                sized(content(member), to: layout.points(fraction(member)))
                if index < members.count - 1 { divider(after: index) }
            }
        }
    }

    @ViewBuilder
    private func stack<Members: View>(@ViewBuilder _ members: () -> Members) -> some View {
        switch axis {
        case .horizontal: HStack(spacing: 0, content: members)
        case .vertical: VStack(spacing: 0, content: members)
        }
    }

    /// Fixed along the axis, filling across it.
    @ViewBuilder
    private func sized(_ member: Content, to points: CGFloat) -> some View {
        switch axis {
        case .horizontal: member.frame(width: points).frame(maxHeight: .infinity)
        case .vertical: member.frame(height: points).frame(maxWidth: .infinity)
        }
    }

    private func divider(after index: Int) -> some View {
        let member = members[index]
        let neighbour = members[index + 1]
        return SplitDivider(
            axis: axis, leading: fraction(member), trailing: fraction(neighbour)
        ) { start, against, translation in
            resize(
                member.id, layout.dragged(from: start, against: against, by: translation),
                neighbour.id)
        }
        // Above the member drawn *after* it, so the half of the grab area that overhangs
        // that side is not buried by it.
        .zIndex(1)
    }
}

// MARK: - SplitDivider

/// The hairline between two members, and the handle that drags it.
///
/// One point of layout, with the grab area an overlay: an overlay does not take part in
/// layout, so the line stays a hairline while the target is wide enough to hit without
/// aiming. `HSplitView`'s own divider did the same thing in AppKit, as a cursor rect wider
/// than the line it draws.
private struct SplitDivider: View {
    let axis: Axis
    let leading: Double
    let trailing: Double
    /// Reports the pair's fractions as they were when the drag began, and the points moved
    /// since. See `SplitLayout.dragged(from:against:by:)` for why it is not the live pair.
    let drag: (_ from: Double, _ against: Double, _ by: CGFloat) -> Void

    /// Non-nil for exactly the length of one drag.
    @State private var began: (leading: Double, trailing: Double)?

    private static let grab: CGFloat = 9

    private var isHorizontal: Bool { axis == .horizontal }

    var body: some View {
        // A palette hairline rather than a system divider, for the reason `AGENTS.md`
        // gives: a system separator is one more colour from one more source.
        Color.border
            .frame(
                width: isHorizontal ? SplitLayout.dividerThickness : nil,
                height: isHorizontal ? nil : SplitLayout.dividerThickness
            )
            .overlay {
                Color.clear
                    .frame(
                        width: isHorizontal ? Self.grab : nil,
                        height: isHorizontal ? nil : Self.grab
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown)
                                .push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(gesture)
            }
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let origin = began ?? (leading: leading, trailing: trailing)
                began = origin
                drag(
                    origin.leading, origin.trailing,
                    isHorizontal ? value.translation.width : value.translation.height)
            }
            .onEnded { _ in began = nil }
    }
}
