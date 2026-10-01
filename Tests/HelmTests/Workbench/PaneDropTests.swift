import HelmWire
import XCTest

@testable import Helm

/// Dragging a tab to another place (#178): which place the pointer means (`PaneDrop.resolve`,
/// helm's), and that a drop goes to benchd as one `pane/move` of the operator's. What the move
/// then does is benchd's, tested in `bench-doc`'s `drop_pane.rs`. No window and no surface, so
/// nothing here is subject to #253.
@MainActor
final class PaneDropTests: XCTestCase {

    // MARK: - The bench: three tabs on the left, two rows on the right

    private let a = Pane(content: .terminal())
    private let b = Pane(content: .terminal())
    private let c = Pane(content: .terminal())
    private let d = Pane(content: .terminal())
    private let e = Pane(content: .terminal())
    private lazy var left = Slot(panes: [a, b, c])
    private lazy var top = Slot(panes: [d], height: 0.5)
    private lazy var bottom = Slot(panes: [e], height: 0.5)
    private lazy var bench = Workbench.assembled(
        columns: [
            Column(slots: [left], width: 0.5), Column(slots: [top, bottom], width: 0.5),
        ],
        focusedSlot: left.id)!

    /// Drawn 800×600: each column 400 wide, the right one's rows 300 tall, strips 28 tall, tabs
    /// 72 wide from x+8.
    private var frames: [Slot.ID: SlotFrames] {
        func slot(_ s: Slot, x: CGFloat, y: CGFloat, height: CGFloat) -> SlotFrames {
            var tabs: [Pane.ID: CGRect] = [:]
            for (i, pane) in s.panes.enumerated() {
                tabs[pane.id] = CGRect(x: x + 8 + CGFloat(i) * 76, y: y + 4, width: 72, height: 20)
            }
            return SlotFrames(
                body: CGRect(x: x, y: y, width: 400, height: height),
                strip: CGRect(x: x, y: y, width: 400, height: 28), tabs: tabs)
        }
        return [
            left.id: slot(left, x: 0, y: 0, height: 600),
            top.id: slot(top, x: 400, y: 0, height: 300),
            bottom.id: slot(bottom, x: 400, y: 300, height: 300),
        ]
    }

    private func resolve(_ pane: Pane, _ x: CGFloat, _ y: CGFloat) -> DropTarget? {
        PaneDrop.resolve(pane: pane.id, at: CGPoint(x: x, y: y), bench: bench, frames: frames)
    }

    // MARK: - Where the pointer means

    func testTheMiddleOfAnotherSlotIsItsLastTab() throws {
        let target = try XCTUnwrap(resolve(a, 600, 150))
        XCTAssertEqual(target.move, .tab(slot: top.id, before: nil))
        XCTAssertEqual(target.preview, frames[top.id]!.body, "the whole slot will show it")
        XCTAssertGreaterThan(
            try XCTUnwrap(target.seam).minX, frames[top.id]!.tabs[d.id]!.maxX, "after its tabs")
    }

    func testAGapInAStripIsBeforeTheTabRightOfThePointer() {
        XCTAssertEqual(resolve(a, 410, 14)?.move, .tab(slot: top.id, before: d.id))
        XCTAssertEqual(
            resolve(a, 470, 14)?.move, .tab(slot: top.id, before: nil), "past d's middle")
        XCTAssertEqual(resolve(c, 20, 14)?.move, .tab(slot: left.id, before: a.id), "a reorder")
    }

    func testAnEdgeBandSplitsBesideTheSlotAndShowsTheHalfItWillTake() throws {
        let up = try XCTUnwrap(resolve(a, 600, 40))
        XCTAssertEqual(up.move, .beside(slot: top.id, side: .up))
        XCTAssertEqual(up.preview, CGRect(x: 400, y: 0, width: 400, height: 150))
        XCTAssertEqual(up.seam?.height, 3, "a bar along the top edge")

        let sideways = try XCTUnwrap(resolve(a, 420, 150))
        XCTAssertEqual(sideways.move, .beside(slot: top.id, side: .left))
        XCTAssertEqual(
            sideways.preview, CGRect(x: 400, y: 0, width: 200, height: 600),
            "a new column: half of the whole column, not of the slot")
    }

    func testATabDroppedOnItsOwnSlotsEdgeBecomesAPaneOfItsOwn() {
        XCTAssertEqual(resolve(a, 390, 300)?.move, .beside(slot: left.id, side: .right))
        XCTAssertEqual(resolve(b, 200, 590)?.move, .beside(slot: left.id, side: .down))
    }

    /// The controls: positions where benchd would leave the pane where it is. A resolver that
    /// answered everything would pass every test above; these fail it.
    func testNoZoneWhereTheDropWouldChangeNothing() {
        XCTAssertNil(resolve(a, 200, 300), "its own slot's middle")
        XCTAssertNil(resolve(b, 100, 14), "before itself")
        XCTAssertNil(resolve(b, 150, 14), "before the tab already after it")
        XCTAssertNil(resolve(c, 390, 14), "the last tab, to the end")
        XCTAssertNil(resolve(e, 600, 310), "a lone pane above itself")
        XCTAssertNil(resolve(e, 600, 450), "…or in its own middle")
        XCTAssertNil(resolve(a, 900, 300), "off the bench")
    }

    /// A lone pane on the facing edge of its neighbour lands where it is (review R1 on #555):
    /// benchd answers `changed: false`, so no zone either.
    func testNoZoneOnTheFacingEdgeOfANeighbour() {
        XCTAssertNil(resolve(e, 600, 290), "the bottom row onto the top row's bottom edge")
        XCTAssertNil(resolve(d, 600, 340), "the top row onto the bottom row's top edge")
        XCTAssertEqual(
            resolve(d, 600, 590)?.move, .beside(slot: bottom.id, side: .down),
            "…while the far edge still moves it")

        let pair = Workbench.assembled(
            columns: [
                Column(slots: [Slot(panes: [d])], width: 0.5),
                Column(slots: [Slot(panes: [e])], width: 0.5),
            ],
            focusedSlot: UUID())!
        let frames = Dictionary(
            uniqueKeysWithValues: pair.columns.enumerated().map { i, column in
                (
                    column.slots[0].id,
                    SlotFrames(
                        body: CGRect(x: CGFloat(i) * 400, y: 0, width: 400, height: 600),
                        strip: CGRect(x: CGFloat(i) * 400, y: 0, width: 400, height: 28))
                )
            })
        func move(_ pane: Pane, _ x: CGFloat) -> BenchMoveTo? {
            PaneDrop.resolve(pane: pane.id, at: CGPoint(x: x, y: 300), bench: pair, frames: frames)?
                .move
        }
        XCTAssertNil(move(d, 410), "onto the right column's left edge")
        XCTAssertNil(move(e, 390), "onto the left column's right edge")
        XCTAssertEqual(move(d, 790), .beside(slot: pair.columns[1].slots[0].id, side: .right))
    }

    func testALonePaneLeavesItsColumnSidewaysOnlyWhenTheColumnHoldsMore() {
        XCTAssertEqual(resolve(e, 790, 450)?.move, .beside(slot: bottom.id, side: .right))
        let alone = Workbench(panes: [d])
        XCTAssertNil(
            PaneDrop.resolve(
                pane: d.id, at: CGPoint(x: 395, y: 300), bench: alone,
                frames: [
                    alone.columns[0].slots[0].id: SlotFrames(
                        body: CGRect(x: 0, y: 0, width: 400, height: 600),
                        strip: CGRect(x: 0, y: 0, width: 400, height: 28))
                ]),
            "the only pane in the only column has nowhere to go")
    }

    // MARK: - The drop

    /// The end of it: a tab released over another slot's edge goes to benchd as one `pane/move`
    /// with that destination, as the operator's gesture — which benchd's focus rule gives the
    /// keyboard, as it does a key.
    func testADropSendsOneMoveAsTheOperator() throws {
        let first = ToyBench.terminal()
        let second = ToyBench.terminal()
        let rig = try toyRig(
            "/tmp/helm-pane-drop",
            document: BenchDocument(
                workspaces: [
                    .init(path: "/tmp/helm-pane-drop", bench: ToyBench.bench([first, second]))
                ],
                active: "/tmp/helm-pane-drop"))
        let slot = try XCTUnwrap(rig.model.bench?.columns.first?.slots.first)
        rig.model.drag.slots = [
            slot.id: SlotFrames(
                body: CGRect(x: 0, y: 0, width: 800, height: 600),
                strip: CGRect(x: 0, y: 0, width: 800, height: 28))
        ]
        let sent = rig.server.verbs.count

        rig.model.dragTab(.pane(second.id), to: CGPoint(x: 780, y: 300))
        XCTAssertNotNil(rig.model.drag.live?.target, "the zone is drawn while dragging")
        rig.model.dropTab(.pane(second.id), at: CGPoint(x: 790, y: 300))

        XCTAssertEqual(rig.server.verbs.count, sent + 1, "one verb")
        let verb = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual(verb["verb"] as? String, "pane/move")
        let args = try XCTUnwrap(verb["args"] as? [String: Any])
        XCTAssertEqual(args["pane"] as? String, second.id.uuidString)
        let beside = try XCTUnwrap((args["to"] as? [String: Any])?["beside"] as? [String: Any])
        XCTAssertEqual(beside["slot"] as? String, slot.id.uuidString)
        XCTAssertEqual(beside["side"] as? String, "right")
        XCTAssertEqual((verb["by"] as? [String: Any])?["kind"] as? String, "operator")
        XCTAssertNil(rig.model.drag.live, "the zone is gone after the drop")

        rig.model.dropTab(.pane(second.id), at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(
            rig.server.verbs.count, sent + 1, "a drop that changes nothing sends nothing")
    }
}

extension DropTarget {
    /// The `pane/move` destination this drop sends, for a test that reads like the resolver's rules.
    fileprivate var move: BenchMoveTo? {
        if case let .paneMove(_, to) = verb { to } else { nil }
    }
}
