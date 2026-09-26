import Foundation
import HelmWire
import XCTest

@testable import Helm

/// helm drawing benchd's drawers (#356), against the stand-in benchd: the drawer is drawn over
/// the bench and changes nothing under it, it keeps its content while hidden, and its key and
/// capsule send `drawer/toggle` as the operator.
@MainActor
final class DrawerTests: XCTestCase {
    private let path = "/tmp/helm-drawers"

    private struct Rig {
        let server: FakeBenchd
        let model: WorkbenchModel
        let terminals: TerminalManager
    }

    private func rig(
        _ first: DocumentAt, makeBrowser: (@MainActor @Sendable () -> BrowserPaneModel)? = nil
    ) throws -> Rig {
        let server = try FakeBenchd(document: first)
        let client = BenchClient(socketPath: server.path)
        let terminals = TerminalManager()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-drawers-\(UUID().uuidString)")
        let model = WorkbenchModel(
            terminals: terminals, agents: .blind,
            makeBrowser: makeBrowser
                ?? { BrowserPaneModel(environment: ["BENCH_DIR": root.path], home: root) },
            mode: .daemon(client))
        addTeardownBlock { @MainActor in
            client.stop()
            server.stop()
        }
        XCTAssertTrue(Eventually.holds { model.document != nil }, "the first document never came")
        if model.restoreOffer != nil { model.answer(.restore) }
        return Rig(server: server, model: model, terminals: terminals)
    }

    private func document(
        _ bench: BenchDocument.Bench, seq: UInt64, drawers: [BenchDocument.Drawer] = [],
        open: String? = nil
    ) -> DocumentAt {
        var at = BenchFixture.document(path, bench, seq: seq)
        at.document.drawers = drawers
        at.document.openDrawer = open
        return at
    }

    private func browserDrawer(_ pane: UUID, badged: Bool = false) -> BenchDocument.Drawer {
        .init(
            name: "browser", panes: [.init(id: pane, surface: .browser)], selected: pane,
            badged: badged)
    }

    /// AC2 at the render layer: the drawer is drawn over the bench, so the bench helm lays out
    /// and what is visible in it are the same with the drawer open as without it.
    func testOpeningADrawerLeavesTheBenchAsItWas() throws {
        let first = UUID()
        let second = UUID()
        let bench = BenchFixture.bench(
            [BenchFixture.terminal(first), BenchFixture.terminal(second)], selected: second)
        let rig = try rig(document(bench, seq: 1))
        let before = try XCTUnwrap(rig.model.bench)

        rig.server.push(document(bench, seq: 2, drawers: [browserDrawer(UUID())], open: "browser"))

        XCTAssertTrue(Eventually.holds { rig.model.openDrawer?.name == "browser" })
        XCTAssertEqual(rig.model.bench, before)
        XCTAssertEqual(rig.model.bench?.visiblePaneIDs, before.visiblePaneIDs)
    }

    /// The keyboard follows the drawer: while one is shown, the bench's focused pane does not
    /// hold it, and when it is hidden the same pane takes it back.
    func testTheBenchGivesUpTheKeyboardWhileADrawerIsShown() throws {
        let first = UUID()
        let bench = BenchFixture.bench([BenchFixture.terminal(first)])
        let rig = try rig(document(bench, seq: 1))
        func focusedHoldsKeyboard() throws -> Bool {
            let bench = try XCTUnwrap(rig.model.bench)
            let pane = try XCTUnwrap(bench.focusedPane)
            let slot = try XCTUnwrap(bench.slot(bench.focusedSlot))
            return rig.model.surfaceSlot(for: pane, in: slot).holdsKeyboard
        }
        XCTAssertTrue(try focusedHoldsKeyboard())

        let drawer = browserDrawer(UUID())
        rig.server.push(document(bench, seq: 2, drawers: [drawer], open: "browser"))
        XCTAssertTrue(Eventually.holds { rig.model.openDrawer != nil })
        XCTAssertFalse(try focusedHoldsKeyboard(), "the drawer has the keyboard while it is shown")

        rig.server.push(document(bench, seq: 3, drawers: [drawer]))
        XCTAssertTrue(Eventually.holds { rig.model.openDrawer == nil })
        XCTAssertTrue(try focusedHoldsKeyboard(), "hidden again, the bench's pane takes it back")
    }

    /// AC4: a drawer's pane is still in the document while the drawer is hidden, so its live
    /// object is kept — one `make` across hide and show — and closing a workspace does not take
    /// it, because a drawer belongs to none.
    func testAHiddenDrawerPaneKeepsItsModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-drawers-\(UUID().uuidString)")
        final class Count: @unchecked Sendable { var value = 0 }
        let made = Count()
        let bench = BenchFixture.bench([BenchFixture.terminal()])
        let paneID = UUID()
        let drawer = browserDrawer(paneID)
        let rig = try rig(
            document(bench, seq: 1, drawers: [drawer], open: "browser"),
            makeBrowser: {
                made.value += 1
                return BrowserPaneModel(environment: ["BENCH_DIR": root.path], home: root)
            })
        let pane = Pane(id: paneID, content: .browser)
        let slot = SurfaceSlot(
            pane: pane, holdsKeyboard: true, isSelected: true, canClose: true, select: {},
            close: {})
        XCTAssertNotNil(rig.model.surfaceView(of: pane, in: slot))

        rig.server.push(document(bench, seq: 2, drawers: [drawer]))
        XCTAssertTrue(Eventually.holds { rig.model.openDrawer == nil })
        rig.model.closeWorkspace(WorkspacePath(path))
        rig.server.push(document(bench, seq: 3, drawers: [drawer], open: "browser"))
        XCTAssertTrue(Eventually.holds { rig.model.openDrawer != nil })
        XCTAssertNotNil(rig.model.surfaceView(of: pane, in: slot))

        XCTAssertEqual(
            made.value, 1, "the same browser view across hide, a workspace close and show")
    }

    /// A drawer key and a capsule click are the operator's `drawer/toggle`, naming the drawer
    /// and what an empty one starts with.
    func testTheDrawerKeySendsDrawerToggleAsTheOperator() throws {
        let rig = try rig(document(BenchFixture.bench([BenchFixture.terminal()]), seq: 1))
        let defaults = try isolatedDefaults("drawer-key")
        let actions = LocalActions(
            workbench: rig.model, workspaces: WorkspaceModel(defaults: defaults),
            rail: ArchonRailModel(client: FakeArchonClient(), defaults: defaults),
            terminals: rig.terminals)

        actions.perform(.verb(.toggleDrawer(name: "browser", surface: .browser)))

        let sent = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual(sent["verb"] as? String, "drawer/toggle")
        XCTAssertEqual((sent["by"] as? [String: Any])?["kind"] as? String, "operator")
        let args = try XCTUnwrap(sent["args"] as? [String: Any])
        XCTAssertEqual(args["drawer"] as? String, "browser")
        XCTAssertEqual((args["surface"] as? [String: Any])?["kind"] as? String, "browser")
    }

    /// One capsule per drawer, lit while it is shown and dotted while it is badged.
    func testCapsulesSayWhichDrawerIsOpenAndWhichIsBadged() {
        let one = UUID()
        let two = UUID()
        var document = BenchFixture.document(
            path, BenchFixture.bench([BenchFixture.terminal()]), seq: 1
        ).document
        document.drawers = [
            .init(name: "browser", panes: [.init(id: one, surface: .browser)], selected: one),
            .init(
                name: "notes", panes: [.init(id: two, surface: .canvas(path: "/tmp/n.md"))],
                selected: two, badged: true),
        ]
        document.openDrawer = "browser"

        XCTAssertEqual(
            DrawerCapsule.of(document),
            [
                DrawerCapsule(name: "browser", isOpen: true, isBadged: false),
                DrawerCapsule(name: "notes", isOpen: false, isBadged: true),
            ])
        XCTAssertEqual(DrawerCapsule.of(nil), [], "local mode has no drawers")
    }
}
