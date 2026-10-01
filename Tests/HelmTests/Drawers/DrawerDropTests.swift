import HelmWire
import XCTest

@testable import Helm

/// Dragging an open drawer to another window edge (#178): which edge the pointer means
/// (`DrawerDrop.resolve`, helm's), that a drop goes to benchd as one `drawer/place` of the
/// operator's, and that the edge benchd keeps is the one helm draws. That an agent cannot place
/// one unasked is benchd's, tested in `bench-doc`'s `drawers.rs` and the CLI conformance suite.
/// No window and no surface, so nothing here is subject to #253.
@MainActor
final class DrawerDropTests: XCTestCase {
    /// A drawer on the right at half the width, over a bench drawn 1000×600 below a 40-point bar.
    private let area = CGRect(x: 0, y: 40, width: 1000, height: 600)
    private lazy var onTheRight = DrawerFrame(
        area: area, style: DrawerStyle(edge: .right, size: 0.5))

    // MARK: - Which edge the pointer means

    func testEachEdgeBandMeansThatEdgeAndShowsTheBandTheDrawerWouldTake() throws {
        let bottom = try XCTUnwrap(
            DrawerDrop.resolve(at: CGPoint(x: 500, y: 600), frame: onTheRight))
        XCTAssertEqual(bottom.to, .drawerEdge(.bottom))
        XCTAssertEqual(bottom.preview, CGRect(x: 0, y: 340, width: 1000, height: 300))
        XCTAssertEqual(bottom.seam, CGRect(x: 0, y: 637, width: 1000, height: 3))

        let left = try XCTUnwrap(DrawerDrop.resolve(at: CGPoint(x: 50, y: 200), frame: onTheRight))
        XCTAssertEqual(left.to, .drawerEdge(.left))
        XCTAssertEqual(left.preview, CGRect(x: 0, y: 40, width: 500, height: 600))
        XCTAssertEqual(left.seam, CGRect(x: 0, y: 40, width: 3, height: 600))
    }

    /// In a corner the nearer edge wins.
    func testTheNearerEdgeWinsInACorner() {
        XCTAssertEqual(
            DrawerDrop.resolve(at: CGPoint(x: 20, y: 620), frame: onTheRight)?.to,
            .drawerEdge(.left), "20 from the left, 20 from the bottom of 600: 2% against 3.3%")
        XCTAssertEqual(
            DrawerDrop.resolve(at: CGPoint(x: 100, y: 635), frame: onTheRight)?.to,
            .drawerEdge(.bottom))
    }

    /// Nowhere draws no zone: the middle of the window, and the edge the drawer is already on,
    /// which is where its own header starts the drag.
    func testTheMiddleAndItsOwnEdgeAreNowhere() {
        XCTAssertNil(DrawerDrop.resolve(at: CGPoint(x: 500, y: 300), frame: onTheRight))
        XCTAssertNil(
            DrawerDrop.resolve(at: CGPoint(x: 950, y: 300), frame: onTheRight),
            "a drop where it already is would promise a move that does not happen")
        XCTAssertNil(
            DrawerDrop.resolve(
                at: CGPoint(x: 500, y: 600),
                frame: DrawerFrame(area: area, style: DrawerStyle(edge: .bottom, size: 0.4))))
    }

    // MARK: - The drop

    /// The end of it: an open drawer's header released against the bottom edge goes to benchd as
    /// one `drawer/place` naming the drawer and the edge, as the operator's gesture.
    func testADropSendsOnePlaceAsTheOperator() throws {
        let rig = try drawerRig()
        rig.model.drag.drawer = onTheRight
        let sent = rig.server.verbs.count

        rig.model.dragTab(.drawer("notes"), to: CGPoint(x: 500, y: 590))
        XCTAssertEqual(
            rig.model.drag.live?.target?.to, .drawerEdge(.bottom),
            "the zone is drawn while dragging")
        rig.model.dropTab(.drawer("notes"), at: CGPoint(x: 500, y: 600))

        XCTAssertEqual(rig.server.verbs.count, sent + 1, "one verb")
        let verb = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual(verb["verb"] as? String, "drawer/place")
        let args = try XCTUnwrap(verb["args"] as? [String: Any])
        XCTAssertEqual(args["drawer"] as? String, "notes")
        XCTAssertEqual(args["edge"] as? String, "bottom")
        XCTAssertEqual((verb["by"] as? [String: Any])?["kind"] as? String, "operator")
        XCTAssertNil(rig.model.drag.live, "the zone is gone after the drop")

        rig.model.dragTab(.drawer("notes"), to: CGPoint(x: 950, y: 300))
        rig.model.dropTab(.drawer("notes"), at: CGPoint(x: 960, y: 300))
        XCTAssertEqual(
            rig.server.verbs.count, sent + 1, "a drop on its own edge sends nothing")
    }

    func testEscapeEndsADrawerDragAndItsReleaseSendsNothing() throws {
        let rig = try drawerRig()
        rig.model.drag.drawer = onTheRight
        let sent = rig.server.verbs.count

        rig.model.dragTab(.drawer("notes"), to: CGPoint(x: 50, y: 300))
        rig.model.drag.cancel()
        rig.model.dropTab(.drawer("notes"), at: CGPoint(x: 50, y: 300))

        XCTAssertEqual(rig.server.verbs.count, sent, "nothing sent")
    }

    // MARK: - The edge helm draws

    /// The document's edge is the operator's and wins; the keymap's (or the built-in) is only the
    /// default for a drawer he has not placed. The size stays the keymap's either way.
    func testTheDocumentsEdgeWinsOverTheKeymapsAndKeepsItsSize() {
        let keymap = DrawerStyle(edge: .right, size: 0.3)
        let placed = BenchDocument(
            workspaces: [], active: nil, drawerEdges: ["notes": .bottom])

        XCTAssertEqual(
            keymap.placed("notes", by: placed), DrawerStyle(edge: .bottom, size: 0.3))
        XCTAssertEqual(keymap.placed("browser", by: placed), keymap, "not placed: the keymap's")
        XCTAssertEqual(keymap.placed("notes", by: nil), keymap, "no document yet")
    }

    // MARK: - Rig

    private func drawerRig() throws -> ToyRig {
        let pane = ToyBench.terminal()
        let path = "/tmp/helm-drawer-drop"
        return try toyRig(
            path,
            document: BenchDocument(
                workspaces: [.init(path: path, bench: ToyBench.bench([ToyBench.terminal()]))],
                active: path,
                drawers: [.init(name: "notes", panes: [pane], selected: pane.id)],
                openDrawer: "notes"))
    }
}
