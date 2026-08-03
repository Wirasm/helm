import XCTest

@testable import Helm

final class WorkbenchArchonPaneTests: XCTestCase {
    private let reference = ArchonPaneRef.run(id: "run-1", workflowName: "implement")

    func testPaneContentRoundTripsAndOldCasesStillDecode() throws {
        for content in [Pane.Content.archonRun(reference), .archonRun(.runs(status: "failed"))] {
            XCTAssertEqual(
                try JSONDecoder().decode(Pane.Content.self, from: JSONEncoder().encode(content)),
                content)
        }

        XCTAssertEqual(
            try JSONDecoder().decode(Pane.Content.self, from: Data(#"{"kind":"terminal"}"#.utf8)),
            .terminal(face: .terminal))
        XCTAssertThrowsError(
            try JSONDecoder().decode(Pane.Content.self, from: Data(#"{"kind":"future"}"#.utf8)))
    }

    /// Through `WorkspaceContextStore` and a real `UserDefaults`, which is the path a restart
    /// takes. A bare `Pane.Content` through a fresh encoder proves the case is `Codable` and
    /// nothing about whether a bench holding one survives being stored.
    func testAnArchonPaneSurvivesTheStoreTheAppActuallyUses() throws {
        var bench = Workbench(terminal: UUID())
        bench.insert(Pane(content: .archonRun(reference)), at: .column)
        bench.insert(
            Pane(content: .archonRun(.runs(status: "failed"))), at: .tab(in: bench.focusedSlot))
        let defaults = try isolatedDefaults("workbench-archon-restore")

        WorkspaceContextStore.save(["/one": WorkspaceContext(workbench: bench)], to: defaults)

        XCTAssertEqual(
            WorkspaceContextStore.load(from: defaults)["/one"]?.workbench, bench,
            "the whole arrangement comes back, including which run each pane was pointed at")
    }

    func testRepeatedRunSelectsExistingPaneAndRunPanesGroupTogether() {
        var bench = Workbench(terminal: UUID())
        let open = Pane(content: .archonRun(reference))
        bench.insert(open, at: .column)

        XCTAssertEqual(bench.placement(forOpening: reference), .existing(open.id))
        XCTAssertEqual(
            bench.placement(forOpening: .run(id: "run-2", workflowName: "review")),
            .tab(in: bench.focusedSlot))
        XCTAssertEqual(
            bench.placement(forOpening: .runs(status: "failed")), .tab(in: bench.focusedSlot),
            "a status list is an Archon pane too, and groups with them")
    }

    @MainActor
    func testWorkbenchCachesRunModelAndDropsItOnClose() throws {
        let manager = TerminalManager()
        let model = WorkbenchModel(terminals: manager, archon: FakeArchonClient())
        model.activate(workspacePath: "/tmp/project")
        let id = try XCTUnwrap(model.openRun(reference))
        let pane = try XCTUnwrap(model.bench?.pane(id))
        let first = model.archonRun(for: pane)

        XCTAssertIdentical(model.archonRun(for: pane), first)
        model.close(id)
        XCTAssertNotIdentical(model.archonRun(for: pane), first)
    }

    @MainActor
    func testClosingWorkspaceDropsItsRunModels() throws {
        let model = WorkbenchModel(terminals: TerminalManager(), archon: FakeArchonClient())
        model.activate(workspacePath: "/tmp/project")
        let id = try XCTUnwrap(model.openRun(reference))
        let pane = try XCTUnwrap(model.bench?.pane(id))
        let first = model.archonRun(for: pane)

        model.closeWorkspace("/tmp/project")

        XCTAssertNotIdentical(model.archonRun(for: pane), first)
    }

    /// With no workspace there is no bench to put a pane on, and `openRun` says so by
    /// returning nil. `ArchonRailView.canOpenRuns` is fed from the same condition, which is
    /// what stops a click landing nowhere at all.
    @MainActor
    func testOpeningARunWithNoWorkspaceFailsVisiblyRatherThanSilently() {
        let model = WorkbenchModel(terminals: TerminalManager(), archon: FakeArchonClient())

        XCTAssertNil(model.bench)
        XCTAssertNil(model.openRun(reference))
    }
}
