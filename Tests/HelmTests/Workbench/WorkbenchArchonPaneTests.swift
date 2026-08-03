import XCTest

@testable import Helm

final class WorkbenchArchonPaneTests: XCTestCase {
    private let reference = ArchonRunRef(id: "run-1", workflowName: "implement")

    func testPaneContentRoundTripsAndOldCasesStillDecode() throws {
        let content = Pane.Content.archonRun(reference)
        XCTAssertEqual(
            try JSONDecoder().decode(Pane.Content.self, from: JSONEncoder().encode(content)),
            content)

        XCTAssertEqual(
            try JSONDecoder().decode(Pane.Content.self, from: Data(#"{"kind":"terminal"}"#.utf8)),
            .terminal(face: .terminal))
        XCTAssertThrowsError(
            try JSONDecoder().decode(Pane.Content.self, from: Data(#"{"kind":"future"}"#.utf8)))
    }

    func testRepeatedRunSelectsExistingPaneAndRunPanesGroupTogether() {
        var bench = Workbench(terminal: UUID())
        let open = Pane(content: .archonRun(reference))
        bench.insert(open, at: .column)

        XCTAssertEqual(bench.placement(forOpening: reference), .existing(open.id))
        XCTAssertEqual(
            bench.placement(forOpening: .init(id: "run-2", workflowName: "review")),
            .tab(in: bench.focusedSlot))
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
}
