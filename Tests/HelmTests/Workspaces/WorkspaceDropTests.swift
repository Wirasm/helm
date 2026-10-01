import HelmWire
import XCTest

@testable import Helm

/// Drops on the workspace bar (#178): which place the pointer means (`WorkspaceDrop.resolve`),
/// that a drop goes to benchd as one verb of the operator's, and that Escape ends a drag without
/// sending anything. What the verbs then do is benchd's, tested in `bench-doc`'s
/// `move_workspace.rs`. No window and no surface, so nothing here is subject to #253.
@MainActor
final class WorkspaceDropTests: XCTestCase {

    // MARK: - The bar: three tabs, 100 wide from x 8, 24 tall

    private let a = WorkspacePath("/w/a")
    private let b = WorkspacePath("/w/b")
    private let c = WorkspacePath("/w/c")
    private var order: [WorkspacePath] { [a, b, c] }

    private var bar: BarFrames {
        var frames = BarFrames(strip: CGRect(x: 0, y: 0, width: 800, height: 34))
        for (i, path) in order.enumerated() {
            frames.tabs[path] = CGRect(x: 8 + CGFloat(i) * 104, y: 5, width: 100, height: 24)
        }
        return frames
    }

    private let pane = UUID()

    /// `a` on screen holding `panes` (by default the dragged terminal and one more); `b` and `c`
    /// a terminal each, and `b` also whatever `bShows` adds.
    private func document(
        _ panes: [BenchDocument.Pane]? = nil, bShows: [BenchDocument.Pane] = []
    ) -> BenchDocument {
        let mine = panes ?? [ToyBench.terminal(pane), ToyBench.terminal()]
        return BenchDocument(
            workspaces: [
                .init(path: a.value, bench: ToyBench.bench(mine)),
                .init(path: b.value, bench: ToyBench.bench([ToyBench.terminal()] + bShows)),
                .init(path: c.value, bench: ToyBench.bench([ToyBench.terminal()])),
            ],
            active: a.value)
    }

    private func resolve(
        _ item: DragItem, _ x: CGFloat, in document: BenchDocument? = nil
    ) -> DropTarget? {
        WorkspaceDrop.resolve(
            item, at: CGPoint(x: x, y: 17), document: document ?? self.document(), frames: bar)
    }

    // MARK: - Reordering

    func testAWorkspaceDroppedInAGapGoesBeforeTheTabRightOfThePointer() throws {
        let target = try XCTUnwrap(resolve(.workspace(c), 20))
        XCTAssertEqual(target.to, .bar(before: a.value))
        XCTAssertEqual(target.preview, bar.strip, "the bar is what changes")
        let seam = try XCTUnwrap(target.seam, "a bar in the gap")
        XCTAssertLessThan(seam.maxX, bar.tabs[a]!.minX + 1)

        XCTAssertEqual(
            resolve(.workspace(a), 790)?.to, .bar(before: nil),
            "past the last tab's middle is the end")
        XCTAssertEqual(
            resolve(.workspace(a), 240)?.to, .bar(before: c.value))
    }

    /// The controls: positions where the order would not change. A resolver that answered every
    /// gap would pass the test above; these fail it.
    func testNoZoneWhereTheOrderWouldNotChange() {
        XCTAssertNil(resolve(.workspace(b), 120), "before itself")
        XCTAssertNil(resolve(.workspace(b), 200), "before its right neighbour")
        XCTAssertNil(resolve(.workspace(c), 790), "the last, to the end")
    }

    // MARK: - A pane onto a workspace

    func testAPaneDroppedOnAnotherWorkspacesTabMovesThere() throws {
        let target = try XCTUnwrap(resolve(.pane(pane), 160))
        XCTAssertEqual(target.to, .workspace(b.value))
        XCTAssertEqual(target.preview, bar.tabs[b], "the tab it goes to is the zone")
        XCTAssertNil(target.seam)
    }

    func testNoZoneForAPaneOverItsOwnWorkspaceAGapOrWhenItIsTheLastPane() {
        XCTAssertNil(resolve(.pane(pane), 50), "its own workspace")
        XCTAssertNil(resolve(.pane(pane), 110), "the gap between two tabs")
        XCTAssertNil(resolve(.pane(pane), 600), "the bar past the tabs")
        XCTAssertNil(
            resolve(.pane(pane), 160, in: document([ToyBench.terminal(pane)])),
            "a workspace's last pane cannot leave it")
    }

    /// A bench holds one pane per canvas file (benchd's `already_shows`), so a canvas dropped on a
    /// workspace already showing that file has no zone, while one showing something else does.
    func testNoZoneForACanvasOnAWorkspaceAlreadyShowingItsFile() {
        let plan = BenchDocument.Pane(id: pane, surface: .canvas(path: "/x/plan.md"))
        let doc = document(
            [plan, ToyBench.terminal()],
            bShows: [.init(id: UUID(), surface: .canvas(path: "/x/plan.md"))])
        XCTAssertNil(resolve(.pane(pane), 160, in: doc), "b already shows plan.md")
        XCTAssertEqual(
            resolve(.pane(pane), 260, in: doc)?.to, .workspace(c.value),
            "c does not")
    }

    /// Files open on a bench (`FileDrop`), never on the bar: over a tab or a gap they resolve
    /// to nothing, so a file can never become a workspace or pane move.
    func testNoZoneForFilesOverTheBar() {
        XCTAssertNil(resolve(.files, 160), "a workspace's tab")
        XCTAssertNil(resolve(.files, 20), "a gap")
    }

    // MARK: - The drop

    private func rig() throws -> ToyRig {
        let bench = ToyBench.bench([ToyBench.terminal(), ToyBench.terminal()])
        let rig = try toyRig(
            a.value,
            document: BenchDocument(
                workspaces: order.map {
                    .init(
                        path: $0.value,
                        bench: $0 == a ? bench : ToyBench.bench([ToyBench.terminal()]))
                },
                active: a.value))
        rig.model.drag.bar = bar
        return rig
    }

    private func lastVerb(_ rig: ToyRig) throws -> (name: String?, args: [String: Any]) {
        let verb = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual((verb["by"] as? [String: Any])?["kind"] as? String, "operator")
        return (verb["verb"] as? String, try XCTUnwrap(verb["args"] as? [String: Any]))
    }

    /// A workspace tab released in a gap goes to benchd as one `workspace/move`, as the
    /// operator's gesture; released where it is, nothing goes.
    func testAWorkspaceDropSendsOneMoveAsTheOperator() throws {
        let rig = try rig()
        let sent = rig.server.verbs.count

        rig.model.dragTab(.workspace(c), to: CGPoint(x: 30, y: 17))
        XCTAssertNotNil(rig.model.drag.live?.target, "the zone is drawn while dragging")
        rig.model.dropTab(.workspace(c), at: CGPoint(x: 20, y: 17))

        XCTAssertEqual(rig.server.verbs.count, sent + 1, "one verb")
        let (name, args) = try lastVerb(rig)
        XCTAssertEqual(name, "workspace/move")
        XCTAssertEqual(args["path"] as? String, c.value)
        XCTAssertEqual(args["before"] as? String, a.value)
        XCTAssertNil(rig.model.drag.live, "the zone is gone after the drop")

        rig.model.dropTab(.workspace(c), at: CGPoint(x: 790, y: 17))
        XCTAssertEqual(
            rig.server.verbs.count, sent + 1, "a drop that changes nothing sends nothing")
    }

    /// A pane's tab released on another workspace's tab goes as one `pane/move` to that workspace.
    func testAPaneDroppedOnAWorkspaceSendsOneMoveAsTheOperator() throws {
        let rig = try rig()
        let moving = try XCTUnwrap(rig.model.bench?.panes.last?.id)
        let sent = rig.server.verbs.count

        rig.model.dropTab(.pane(moving), at: CGPoint(x: 260, y: 17))

        XCTAssertEqual(rig.server.verbs.count, sent + 1)
        let (name, args) = try lastVerb(rig)
        XCTAssertEqual(name, "pane/move")
        XCTAssertEqual(
            (args["pane"] as? String)?.lowercased(), moving.uuidString.lowercased())
        XCTAssertEqual((args["to"] as? [String: Any])?["workspace"] as? String, c.value)
    }

    // MARK: - Escape

    /// Escape mid-drag takes the zone away, and the release that follows sends nothing — the
    /// gesture keeps reporting until the button comes up, so the pointer moving again must not
    /// bring the zone back either. The next drag is an ordinary one.
    func testEscapeEndsADragAndItsReleaseSendsNothing() throws {
        let rig = try rig()
        let sent = rig.server.verbs.count

        rig.model.dragTab(.workspace(c), to: CGPoint(x: 30, y: 17))
        XCTAssertNotNil(rig.model.drag.live?.target)
        rig.model.drag.cancel()
        XCTAssertNil(rig.model.drag.live, "the zone goes at once")
        rig.model.dragTab(.workspace(c), to: CGPoint(x: 25, y: 17))
        XCTAssertNil(rig.model.drag.live, "…and stays gone while the button is still down")
        rig.model.dropTab(.workspace(c), at: CGPoint(x: 20, y: 17))
        XCTAssertEqual(rig.server.verbs.count, sent, "a cancelled drag sends nothing")

        rig.model.dropTab(.workspace(c), at: CGPoint(x: 20, y: 17))
        XCTAssertEqual(rig.server.verbs.count, sent + 1, "the next drag drops as usual")
    }
}
