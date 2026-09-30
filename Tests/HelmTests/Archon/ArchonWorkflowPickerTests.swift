import XCTest

@testable import Helm

/// The workflow Send launches (#528): seeded to `archon-ship` when nothing usable is chosen, and
/// picked from a list filtered the way the ⌘K palette filters.
final class ArchonWorkflowPickerTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/project")

    @MainActor
    private func model(
        _ names: [String], stored: String, _ suite: String
    ) throws -> ArchonModel {
        let client = FakeArchonClient(
            workflowList: .init(
                workflows: names.map {
                    ArchonWorkflow(name: $0, description: "", provider: nil, model: nil)
                }, errors: []))
        let model = ArchonModel(client: client, defaults: try isolatedDefaults(suite))
        model.config.workflow = stored
        return model
    }

    /// Nothing stored, and a stored name this workspace does not have, are both "nothing
    /// chosen here": the operator's own stored choice was a workflow helm's checkout lacks.
    @MainActor
    func testArchonShipIsTheDefaultWhenNothingUsableIsChosen() async throws {
        for stored in ["", "archon-fix-github-issue-experimental"] {
            let model = try model(
                ["archon-assist", "archon-ship", "archon-plan"], stored: stored,
                "archon-default-\(stored.count)")
            await model.loadWorkflows(in: workspace)
            XCTAssertEqual(model.config.workflow, "archon-ship", "stored: '\(stored)'")
            XCTAssertNil(model.workflowNote)
            XCTAssertFalse(model.isConfigOpen, "loading the list opens nothing")
            XCTAssertFalse(model.isPickingWorkflow, "loading the list opens nothing")
        }
    }

    /// The control: a choice the workspace has is the operator's, and the default must not
    /// overwrite it.
    @MainActor
    func testAChoiceTheWorkspaceHasIsKept() async throws {
        let model = try model(
            ["archon-assist", "archon-ship", "archon-plan"], stored: "archon-plan",
            "archon-default-kept")
        await model.loadWorkflows(in: workspace)
        XCTAssertEqual(model.config.workflow, "archon-plan")
    }

    /// Without `archon-ship` the first workflow is picked, as before, and the drawer says why.
    @MainActor
    func testWithoutArchonShipTheFirstIsPickedAndItSaysSo() async throws {
        let model = try model(["plan", "review"], stored: "", "archon-default-fallback")
        await model.loadWorkflows(in: workspace)
        XCTAssertEqual(model.config.workflow, "plan")
        XCTAssertEqual(model.workflowNote, "no archon-ship here")

        model.pick("review")
        XCTAssertEqual(model.config.workflow, "review")
        XCTAssertNil(model.workflowNote, "a pick is a choice, so the note about the default goes")
    }

    /// Typing filters with the palette's matcher: every letter in order, best first.
    @MainActor
    func testTypingFiltersTheList() async throws {
        let model = try model(
            ["archon-assist", "archon-ship", "archon-smart-pr-review", "archon-plan"], stored: "",
            "archon-filter")
        await model.loadWorkflows(in: workspace)

        XCTAssertEqual(model.workflows(matching: "ship").map(\.name), ["archon-ship"])
        XCTAssertEqual(
            model.workflows(matching: "sp").map(\.name), ["archon-smart-pr-review", "archon-ship"],
            "letters that start words rank first: s-mart p-r over s-hi-p")
        XCTAssertEqual(model.workflows(matching: "plan").map(\.name), ["archon-plan"])
        XCTAssertEqual(model.workflows(matching: "zzz").map(\.name), [])
        XCTAssertEqual(model.workflows(matching: "").count, 4, "an empty query is the whole list")
    }

    /// Picking closes the list.
    @MainActor
    func testOpeningThePickerLoadsTheListAndPickingClosesIt() async throws {
        let model = try model(["plan", "archon-ship"], stored: "", "archon-picker-open")
        await model.openWorkflowPicker(in: workspace)
        XCTAssertTrue(model.isPickingWorkflow)
        XCTAssertEqual(model.workflows.map(\.name), ["plan", "archon-ship"])
        model.pick("plan")
        XCTAssertFalse(model.isPickingWorkflow)
        XCTAssertEqual(model.config.workflow, "plan")
    }
}
