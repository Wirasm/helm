import XCTest

@testable import Helm

/// The bench's geometry arithmetic, without a window.
///
/// **This is #90's test.** The bench used to hand its restored fractions to `HSplitView`
/// through `idealWidth`, which that view ignores — so the sizes on screen were an even
/// split whatever was stored, and the even split was measured straight back over the
/// stored values. Nothing in that path was assertable: the failure lived between a
/// `GeometryReader` and a framework that was not listening. Computing the points instead
/// of measuring them puts the whole restore in reach of `XCTAssertEqual`.
final class SplitLayoutTests: XCTestCase {

    // MARK: - Restore

    /// The operator's dragged 2+1+1, laid out. What came back before this was three
    /// equal thirds.
    func testAStoredFractionIsLaidOutAtExactlyThatFraction() {
        let layout = SplitLayout(extent: 902, members: 3, minimumExtent: 240)

        XCTAssertEqual(layout.available, 900, "two 1pt dividers are not the members' to share")
        XCTAssertEqual(layout.points(0.3349), 301.41, accuracy: 1e-9)
        XCTAssertEqual(layout.points(0.4750), 427.5, accuracy: 1e-9)
        XCTAssertEqual(layout.points(0.1901), 171.09, accuracy: 1e-9)
    }

    func testTheMembersFillTheStackBetweenTheDividers() {
        let layout = SplitLayout(extent: 1000, members: 4, minimumExtent: 240)
        let fractions = [0.4, 0.3, 0.2, 0.1]

        let total = fractions.map(layout.points).reduce(0, +)

        XCTAssertEqual(
            total + SplitLayout.dividerThickness * 3, 1000, accuracy: 1e-9,
            "members plus dividers account for the whole stack, with nothing left over")
    }

    /// A stack with no extent yet — the first layout pass, before the window has a size.
    /// It must produce zero rather than a negative or a NaN, and above all must not be a
    /// signal that anything changed.
    func testAStackWithNoExtentYetHasNothingToHandOut() {
        let layout = SplitLayout(extent: 0, members: 3, minimumExtent: 240)

        XCTAssertEqual(layout.available, 0, "not a negative, whatever the divider allowance")
        XCTAssertEqual(layout.points(0.5), 0)
        XCTAssertEqual(
            layout.dragged(from: 0.5, against: 0.5, by: 200), 0.5,
            "and a drag against nothing changes nothing")
    }

    func testASingleMemberKeepsTheWholeStack() {
        let layout = SplitLayout(extent: 800, members: 1, minimumExtent: 240)

        XCTAssertEqual(layout.available, 800, "there is no divider to pay for")
        XCTAssertEqual(layout.points(1), 800)
    }

    // MARK: - Dragging

    func testADragMovesTheMemberByTheDistanceDragged() {
        let layout = SplitLayout(extent: 1001, members: 2, minimumExtent: 240)

        let dragged = layout.dragged(from: 0.5, against: 0.5, by: 100)

        XCTAssertEqual(dragged, 0.6, accuracy: 1e-9, "100 of 1000 points is a tenth of the stack")
    }

    /// The translation a `DragGesture` reports is measured from where the drag began, so
    /// the fractions it is applied to have to be the ones from then. Applying it to the
    /// live pair would compound it every frame and the divider would run away.
    func testADragIsAppliedToWhereItBeganAndNotToWhereItHasReached() {
        let layout = SplitLayout(extent: 1001, members: 2, minimumExtent: 240)

        let halfway = layout.dragged(from: 0.5, against: 0.5, by: 50)
        let allTheWay = layout.dragged(from: 0.5, against: 0.5, by: 100)

        XCTAssertEqual(halfway, 0.55, accuracy: 1e-9)
        XCTAssertEqual(
            allTheWay, 0.6, accuracy: 1e-9,
            "the second report of the same drag lands where the drag has reached, not 100 "
                + "points past where the first one left it")
    }

    func testADragCannotSqueezeItsOwnMemberBelowTheMinimum() {
        let layout = SplitLayout(extent: 1001, members: 2, minimumExtent: 240)

        let dragged = layout.dragged(from: 0.5, against: 0.5, by: -900)

        XCTAssertEqual(dragged, 0.24, accuracy: 1e-9, "240 of 1000 points, and no further")
    }

    func testADragCannotSqueezeItsNeighbourBelowTheMinimum() {
        let layout = SplitLayout(extent: 1001, members: 2, minimumExtent: 240)

        let dragged = layout.dragged(from: 0.5, against: 0.5, by: 900)

        XCTAssertEqual(
            dragged, 0.76, accuracy: 1e-9,
            "the far side of the divider is clamped by the same minimum as the near side")
    }

    /// The pair, not the stack: a divider between the second and third of four columns can
    /// only ever move within what those two have.
    func testADragIsClampedInsideThePairItSitsBetween() {
        let layout = SplitLayout(extent: 1003, members: 4, minimumExtent: 100)

        let dragged = layout.dragged(from: 0.2, against: 0.2, by: 900)

        XCTAssertEqual(
            dragged, 0.3, accuracy: 1e-9,
            "0.4 between them, less the neighbour's 100 of 1000 points")
    }

    /// A window too narrow for both sides to have the point minimum. The minimum has to
    /// give way to something — and half the pair is the only answer that does not hand out
    /// more than there is.
    func testAStackTooSmallForTheMinimumFallsBackToHalfThePair() {
        let layout = SplitLayout(extent: 301, members: 2, minimumExtent: 240)

        XCTAssertEqual(
            layout.dragged(from: 0.5, against: 0.5, by: -900), 0.5, accuracy: 1e-9,
            "480 points of minimum will not fit in 300, so neither side may take more than half")
        XCTAssertEqual(
            layout.dragged(from: 0.5, against: 0.5, by: 900), 0.5, accuracy: 1e-9)
    }
}
