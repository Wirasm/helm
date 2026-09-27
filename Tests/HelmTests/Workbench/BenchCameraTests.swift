import CoreGraphics
import XCTest

@testable import Helm

/// ⌘J's camera, without a window: where the zoomed slot lands and what peeks in around it.
final class BenchCameraTests: XCTestCase {
    private let window = CGSize(width: 1201, height: 801)

    /// The operator's 2+1: a full-height column on the left, two slots stacked on the right.
    private func twoPlusOne(
        focus: KeyPath<(left: Slot, top: Slot, bottom: Slot), Slot>
    )
        -> Workbench
    {
        let slots = (
            left: Slot(panes: [Pane(content: .terminal())]),
            top: Slot(panes: [Pane(content: .terminal())], height: 0.5),
            bottom: Slot(panes: [Pane(content: .terminal())], height: 0.5)
        )
        return Workbench.assembled(
            columns: [
                Column(slots: [slots.left], width: 0.5),
                Column(slots: [slots.top, slots.bottom], width: 0.5),
            ],
            focusedSlot: slots[keyPath: focus].id)!
    }

    /// The focused slot's rectangle on screen, laid out the way the view draws it.
    private func onScreen(_ camera: BenchCamera, tile: CGRect) -> CGRect {
        tile.offsetBy(dx: -camera.pan.x, dy: -camera.pan.y)
    }

    /// A slot half the window each way is lifted on both axes to its share, and, sitting in the
    /// bench's top-right corner, it is held flush with the window's corner rather than centred
    /// over empty canvas — so everything the window does not give it goes to the left column.
    func testACornerSlotIsLiftedOnBothAxesAndItsNeighboursPeekFromTheOtherSides() {
        let camera = BenchCamera.framing(twoPlusOne(focus: \.top), in: window)

        XCTAssertEqual(camera.canvas.width, (1201 * 1201 * 0.85 / 600).rounded())
        XCTAssertEqual(camera.canvas.height, (801 * 801 * 0.85 / 400).rounded())
        XCTAssertEqual(camera.pan.x, camera.canvas.width - window.width, "flush right")
        XCTAssertEqual(camera.pan.y, 0, "flush top")
    }

    /// A column of one slot already spans the height: growing the box vertically would push
    /// its own top and bottom off the window. Only the width is lifted.
    func testAFullHeightSlotIsLiftedOnlyAcross() {
        let camera = BenchCamera.framing(twoPlusOne(focus: \.left), in: window)

        XCTAssertEqual(camera.canvas.height, window.height)
        XCTAssertGreaterThan(camera.canvas.width, window.width)
        XCTAssertEqual(camera.pan, .zero, "the left column is flush with the window's left edge")
    }

    /// A slot in the middle is centred, so the neighbours peek in from both sides equally.
    func testAMiddleSlotIsCentred() {
        let slots = (0..<3).map { _ in Slot(panes: [Pane(content: .terminal())]) }
        let bench = Workbench.assembled(
            columns: slots.map { Column(slots: [$0], width: 1.0 / 3) }, focusedSlot: slots[1].id)!

        let camera = BenchCamera.framing(bench, in: window)

        let columnWidth = SplitLayout(extent: camera.canvas.width, memberCount: 3, minimumExtent: 0)
            .points(1.0 / 3)
        let tile = CGRect(x: columnWidth + 1, y: 0, width: columnWidth, height: window.height)
        let shown = onScreen(camera, tile: tile)
        XCTAssertEqual(shown.minX, window.width - shown.maxX, accuracy: 0.5)
        XCTAssertEqual(shown.width, window.width * BenchCamera.share, accuracy: 2)
    }

    /// A bench of one slot has nothing around it to show; the camera is the identity, so ⌘J
    /// there changes nothing on screen.
    func testASingleSlotIsNotZoomed() {
        let bench = Workbench(panes: [Pane(content: .terminal())])

        XCTAssertEqual(BenchCamera.framing(bench, in: window), .identity(window))
    }

    /// In a window too small for the share and a peek on both sides, the peek wins: a slot is
    /// never lifted so far that its neighbours shrink to a hairline.
    func testThePeekFloorHoldsInASmallWindow() {
        let small = CGSize(width: 400, height: 300)
        let camera = BenchCamera.framing(twoPlusOne(focus: \.top), in: small)

        let columnWidth = SplitLayout(extent: camera.canvas.width, memberCount: 2, minimumExtent: 0)
            .points(0.5)
        XCTAssertLessThanOrEqual(columnWidth, small.width - 2 * BenchCamera.peek + 1)
    }

    /// The window never leaves the canvas, whichever slot is focused.
    func testThePanStaysInsideTheCanvas() {
        for focus in [\(left: Slot, top: Slot, bottom: Slot).left, \.top, \.bottom] {
            let camera = BenchCamera.framing(twoPlusOne(focus: focus), in: window)
            XCTAssertGreaterThanOrEqual(camera.pan.x, 0)
            XCTAssertGreaterThanOrEqual(camera.pan.y, 0)
            XCTAssertLessThanOrEqual(camera.pan.x, camera.canvas.width - window.width)
            XCTAssertLessThanOrEqual(camera.pan.y, camera.canvas.height - window.height)
        }
    }
}
