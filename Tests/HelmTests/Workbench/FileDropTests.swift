import HelmWire
import XCTest

@testable import Helm

/// A file dragged in from Finder (#178): where the pointer means (`PaneDrop.resolve` with no
/// pane), and that a drop goes to benchd as `pane/open` at that place, as the operator's gesture.
/// Driven through `WorkbenchModel.dragFiles`/`dropFiles`, the handler `FileDropDelegate` hands the
/// drop to, so no window, no real drag and no focus. What opening there does is benchd's, tested
/// in `bench-doc`'s `drop_pane.rs`.
@MainActor
final class FileDropTests: XCTestCase {

    // MARK: - Where the pointer means

    private let a = Pane(content: .terminal())
    private let b = Pane(content: .terminal())
    private lazy var slot = Slot(panes: [a, b])
    private lazy var bench = Workbench.assembled(
        columns: [Column(slots: [slot], width: 1)], focusedSlot: slot.id)!

    /// 800×600, a 28-tall strip, tabs 72 wide from x 8.
    private var frames: [Slot.ID: SlotFrames] {
        [
            slot.id: SlotFrames(
                body: CGRect(x: 0, y: 0, width: 800, height: 600),
                strip: CGRect(x: 0, y: 0, width: 800, height: 28),
                tabs: [
                    a.id: CGRect(x: 8, y: 4, width: 72, height: 20),
                    b.id: CGRect(x: 84, y: 4, width: 72, height: 20),
                ])
        ]
    }

    private func resolve(_ x: CGFloat, _ y: CGFloat) -> PaneDropTarget? {
        PaneDrop.resolve(pane: nil, at: CGPoint(x: x, y: y), bench: bench, frames: frames)
    }

    func testAFileOverAStripGapGoesInThatGap() {
        XCTAssertEqual(resolve(20, 14)?.place, .tab(slot: slot.id, before: a.id))
        XCTAssertEqual(resolve(100, 14)?.place, .tab(slot: slot.id, before: b.id))
        XCTAssertEqual(
            resolve(500, 14)?.place, .tab(slot: slot.id, before: nil),
            "past the last tab, where no pane is already last: the file is no tab yet")
    }

    func testAFileOverAnEdgeBandOpensBesideTheSlot() {
        XCTAssertEqual(resolve(790, 300)?.place, .beside(slot: slot.id, side: .right))
        XCTAssertEqual(resolve(400, 590)?.place, .beside(slot: slot.id, side: .down))
    }

    /// The control: a slot's middle is the pane's own body, where a terminal or a page decides
    /// what a drop does. A resolver that answered "as its last tab" there, as it does for a
    /// dragged tab, would pass both tests above.
    func testAFileOverABodysMiddleIsNowhere() {
        XCTAssertNil(resolve(400, 300))
        XCTAssertNil(resolve(900, 300), "off the bench")
    }

    // MARK: - The drop

    private let path = "/tmp/helm-file-drop"

    private func rig() throws -> (ToyRig, Slot) {
        let rig = try toyRig(path)
        let slot = try XCTUnwrap(rig.model.bench?.columns.first?.slots.first)
        rig.model.paneDrag.frames = [
            slot.id: SlotFrames(
                body: CGRect(x: 0, y: 0, width: 800, height: 600),
                strip: CGRect(x: 0, y: 0, width: 800, height: 28))
        ]
        return (rig, slot)
    }

    private func args(_ verb: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(verb["args"] as? [String: Any])
    }

    private func path(of args: [String: Any]) -> String? {
        ((args["surface"] as? [String: Any])?["source"] as? [String: Any])?["path"] as? String
    }

    /// The end of it: a markdown file let go over a slot's right edge goes to benchd as one
    /// `pane/open` at `beside` that slot, a canvas of that file, as the operator's gesture.
    func testADroppedFileOpensAtThePlaceAsTheOperator() throws {
        let (rig, slot) = try rig()
        let sent = rig.server.verbs.count

        XCTAssertTrue(rig.model.dragFiles(at: CGPoint(x: 780, y: 300)))
        XCTAssertNotNil(rig.model.paneDrag.drag?.target, "the zone is drawn while dragging")
        rig.model.dropFiles(
            [URL(fileURLWithPath: "/tmp/plan.md")], at: CGPoint(x: 790, y: 300))

        XCTAssertEqual(rig.server.verbs.count, sent + 1, "one verb")
        let verb = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual(verb["verb"] as? String, "pane/open")
        let args = try args(verb)
        let beside = try XCTUnwrap((args["at"] as? [String: Any])?["beside"] as? [String: Any])
        XCTAssertEqual(beside["slot"] as? String, slot.id.uuidString)
        XCTAssertEqual(beside["side"] as? String, "right")
        XCTAssertEqual(path(of: args), "/tmp/plan.md")
        XCTAssertNil(args["workspace"], "the place's slot names its bench")
        XCTAssertEqual((verb["by"] as? [String: Any])?["kind"] as? String, "operator")
        XCTAssertNil(rig.model.paneDrag.drag, "the zone is gone after the drop")
    }

    /// The rest are tabbed into the first file's slot, read off the drawn document. When that
    /// pane is not in it (the frame never came), the rest are named rather than lost.
    func testFilesLeftUnopenedBecauseTheFirstPaneIsNotDrawnAreNamed() throws {
        let (rig, _) = try rig()
        rig.server.answer = { request in
            [
                "id": request["id"] ?? "", "status": "ok",
                "data": [
                    "seq": 0, "changed": false, "pane_created": UUID().uuidString.lowercased(),
                ],
            ]
        }
        let sent = rig.server.verbs.count

        rig.model.dropFiles(
            ["/tmp/a.md", "/tmp/b.html"].map { URL(fileURLWithPath: $0) },
            at: CGPoint(x: 400, y: 590))

        XCTAssertEqual(rig.server.verbs.count, sent + 1, "only the first was sent")
        XCTAssertTrue(
            rig.model.verbFailure?.contains("b.html") == true,
            rig.model.verbFailure ?? "said nothing")
    }

    func testSeveralFilesOpenTheFirstAtThePlaceAndTheRestAsTabsBesideIt() throws {
        let (rig, slot) = try rig()
        let sent = rig.server.verbs.count

        rig.model.dropFiles(
            ["/tmp/a.md", "/tmp/b.html"].map { URL(fileURLWithPath: $0) },
            at: CGPoint(x: 400, y: 590))

        XCTAssertEqual(rig.server.verbs.count, sent + 2)
        guard rig.server.verbs.count == sent + 2 else { return }
        let (first, second) = (rig.server.verbs[sent], rig.server.verbs[sent + 1])
        XCTAssertEqual(path(of: try args(first)), "/tmp/a.md")
        XCTAssertEqual(
            ((try args(first)["at"] as? [String: Any])?["beside"] as? [String: Any])?["slot"]
                as? String, slot.id.uuidString)
        XCTAssertEqual(path(of: try args(second)), "/tmp/b.html")
        let tab = try XCTUnwrap(
            (try args(second)["at"] as? [String: Any])?["tab"] as? [String: Any])
        func isCanvas(_ pane: Pane) -> Bool {
            if case .canvas = pane.content { return true }
            return false
        }
        let landed = try XCTUnwrap(
            rig.model.bench?.slots.first { $0.panes.contains(where: isCanvas) })
        XCTAssertEqual(tab["slot"] as? String, landed.id.uuidString, "into the first one's slot")
        XCTAssertNil(tab["before"], "last")
    }

    /// The controls on the drop: where nothing should be sent, nothing is.
    func testNothingIsSentOverABodysMiddleOrForAFileHelmCannotRender() throws {
        let (rig, _) = try rig()
        let sent = rig.server.verbs.count

        XCTAssertFalse(rig.model.dragFiles(at: CGPoint(x: 400, y: 300)))
        rig.model.dropFiles([URL(fileURLWithPath: "/tmp/plan.md")], at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(rig.server.verbs.count, sent, "a body's middle is the pane's")
        XCTAssertNil(rig.model.paneDrag.drag)

        rig.model.dropFiles(
            [URL(fileURLWithPath: "/tmp/photo.png")], at: CGPoint(x: 790, y: 300))
        XCTAssertEqual(rig.server.verbs.count, sent, "not markdown or HTML")
        XCTAssertTrue(
            rig.model.verbFailure?.contains("photo.png") == true,
            rig.model.verbFailure ?? "said nothing")
    }

    /// Over TCP the file is on this Mac and benchd is not: helm says so rather than sending a path
    /// the other machine would read as its own.
    func testOverTCPTheDropIsRefusedSayingTheFileIsOnThisMac() throws {
        let document = BenchDocument.only(path, ToyBench.bench([ToyBench.terminal()]))
        let server = try FakeBenchd(document: DocumentAt(seq: 1, document: document), tcp: true)
        server.playToyBench()
        let client = BenchClient(endpoint: server.endpoint)
        addTeardownBlock { @MainActor in
            client.stop()
            server.stop()
        }
        let model = WorkbenchModel(terminals: TerminalManager(), client: client)
        XCTAssertNotNil(client.document(atLeast: 1, within: 5), "the first document never came")
        let slot = try XCTUnwrap(model.bench?.columns.first?.slots.first)
        model.paneDrag.frames = [
            slot.id: SlotFrames(
                body: CGRect(x: 0, y: 0, width: 800, height: 600),
                strip: CGRect(x: 0, y: 0, width: 800, height: 28))
        ]
        let sent = server.verbs.count

        XCTAssertTrue(model.dragFiles(at: CGPoint(x: 790, y: 300)), "taken, to say why")
        XCTAssertNil(model.paneDrag.drag?.target, "but no zone: nothing will open there")
        model.dropFiles([URL(fileURLWithPath: "/tmp/plan.md")], at: CGPoint(x: 790, y: 300))

        XCTAssertEqual(server.verbs.count, sent)
        XCTAssertTrue(
            model.verbFailure?.contains("on this Mac") == true, model.verbFailure ?? "said nothing")
    }
}
