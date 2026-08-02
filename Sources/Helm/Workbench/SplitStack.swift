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
    /// How many members share it — a count, and named so it cannot be misread as
    /// `SplitStack.members`, which is the array one call site away.
    let memberCount: Int
    /// The smallest a member may be **dragged** to.
    ///
    /// It was `HSplitView`'s `minWidth` to enforce at every layout; helm enforces it where
    /// the operator can feel it. A window resized below `members × minimumExtent` therefore
    /// scales the fractions down rather than overflowing, which is the better of the two
    /// behaviours and the only one that keeps the fractions meaning what they say.
    let minimumExtent: CGFloat

    /// What the members have to share, once the dividers have taken theirs.
    var available: CGFloat {
        max(extent - Self.dividerThickness * CGFloat(max(memberCount - 1, 0)), 0)
    }

    /// A stored fraction, in points. **The whole restore path** — computed, never measured.
    ///
    /// The `max` guards an invariant `Workbench.normalize()` already enforces on every
    /// mutation and on decode, so it is defence in depth rather than a live case — said
    /// here so a later reader does not go looking for the caller that sends a negative.
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
        let moved = start + Double(translation / available)
        return min(max(moved, least), pair - least)
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
        SplitLayout(extent: extent, memberCount: members.count, minimumExtent: minimumExtent)
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

    /// True for exactly as long as this divider owns a pushed cursor. See `pop()`.
    @State private var pushedCursor = false

    private static let grab: CGFloat = 9

    private var isHorizontal: Bool { axis == .horizontal }

    var body: some View {
        // A palette hairline rather than a system divider, for the reason `AGENTS.md`
        // gives: a system separator is one more colour from one more source.
        fixed(Color.border, to: SplitLayout.dividerThickness)
            .overlay {
                fixed(Color.clear, to: Self.grab)
                    .contentShape(Rectangle())
                    .onHover { $0 ? push() : pop() }
                    // **Not belt and braces — the only thing that balances the common
                    // case.** See `pop()`.
                    .onDisappear(perform: pop)
                    .gesture(gesture)
            }
    }

    /// Fixed along the axis, natural across it — which is what the two mirrored `frame`
    /// calls this replaces each produced.
    @ViewBuilder
    private func fixed(_ view: some View, to length: CGFloat) -> some View {
        switch axis {
        case .horizontal: view.frame(width: length)
        case .vertical: view.frame(height: length)
        }
    }

    private func push() {
        guard !pushedCursor else { return }
        pushedCursor = true
        (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
    }

    /// **`NSCursor` push/pop is a stack, and AppKit does not unwind it for you.** No final
    /// exit is synthesized for a tracking area whose view is removed while the pointer is
    /// still inside it — so closing a pane with ⌘W while the mouse rests on a divider used
    /// to leave a push that nothing would ever balance, and a resize cursor stuck over the
    /// whole app until relaunch. A later matched pair cannot undo an entry beneath it.
    ///
    /// The flag is what makes both callers safe: `onDisappear` after an ordinary exit must
    /// not pop a second time, and nothing here may pop a cursor it did not push.
    private func pop() {
        guard pushedCursor else { return }
        pushedCursor = false
        NSCursor.pop()
    }

    /// **`.global`, and it is load-bearing.** A `DragGesture` reports its translation in
    /// its own view's space by default, and this view MOVES as the drag updates the model
    /// that positions it — so the divider chases the cursor and the translation is measured
    /// against a ruler running away underneath it. Measured on a real drag: 120 points of
    /// mouse moved the divider 60. Halved, not broken, which is exactly the kind of thing
    /// that ships. A space the drag cannot move is the fix.
    private var gesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
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
