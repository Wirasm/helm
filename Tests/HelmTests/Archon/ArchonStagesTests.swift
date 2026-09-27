import XCTest

@testable import Helm

/// A run's stage dots (#382), from what Archon's CLI printed on this machine: `workflow runs
/// --json` (the stage list, `terminal_graph`) and `workflow status --json --verbose` (the fold of
/// each live run's events, `nodes`). Paths in the captures are redacted, ids are real.
final class ArchonStagesTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// Every stage of the workflow is a dot, in order, including the ones not reached; the one
    /// Archon is in is `running`; nodes inside a stage (`candidates.step`, a loop's body) get no
    /// dot of their own.
    func testALiveRunIsOneDotPerStageInWorkflowOrder() throws {
        let status = try JSONDecoder.archon().decode(
            ArchonStatusResponse.self, from: fixture("workflow-status-verbose"))
        let run = try XCTUnwrap(status.runs.first)

        let stages = try XCTUnwrap(run.stages())

        XCTAssertEqual(stages.map(\.id), ["intake", "candidates", "report"])
        XCTAssertEqual(stages.map(\.state), [.completed, .completed, .running])
        XCTAssertEqual(stages.first?.durationMs, 2162)
    }

    /// `workflow runs` carries the stage list but not the fold, so a finished run's dots would
    /// be guesses — a completed run can have skipped stages, a failed one does not say where. It
    /// has no stages until Archon's `runs --verbose`; the drawer shows its outcome instead.
    func testAFinishedRunWithoutItsNodesHasNoStages() throws {
        let runs = try JSONDecoder.archon().decode(
            ArchonRunsResponse.self, from: fixture("workflow-runs-graph"))
        let finished = try XCTUnwrap(runs.runs.first)
        XCTAssertEqual(
            finished.metadata?.terminalGraph?.nodeIds, ["intake", "candidates", "report"])

        XCTAssertNil(finished.stages())
        XCTAssertEqual(
            finished.stages(nodes: [.fixture(nodeId: "intake", state: .completed)])?.map(\.state),
            [.completed, .pending, .pending],
            "given its nodes, a finished run is drawn like any other")
    }

    /// A run from before Archon recorded its graph has nothing to draw dots from.
    func testARunWithoutAGraphHasNoStages() throws {
        let runs = try JSONDecoder.archon().decode(
            ArchonRunsResponse.self, from: fixture("workflow-runs-graph"))
        let old = try XCTUnwrap(runs.runs.first { $0.metadata?.terminalGraph == nil })

        XCTAssertNil(old.stages(nodes: [.fixture(nodeId: "plan", state: .completed)]))
    }

    /// The stage a paused run stopped at is `paused`, not `running`: it is waiting on someone.
    func testThePausedRunsStageIsPaused() {
        let run = ArchonRun.fixture(
            status: "paused", nodes: [.fixture(nodeId: "build", state: .completed)],
            graph: ["build", "approve", "ship"], active: ["approve"])

        XCTAssertEqual(run.stages()?.map(\.state), [.completed, .paused, .pending])
        XCTAssertEqual(run.currentStage, "approve")
    }

    /// Failed and skipped stages keep their state and the failure its error.
    func testFailedAndSkippedStagesKeepTheirState() {
        let run = ArchonRun.fixture(
            status: "running",
            nodes: [
                .fixture(nodeId: "a", state: .skipped),
                ArchonNode(
                    nodeId: "b", state: .failed, startedAt: nil, durationMs: 40,
                    outputPreview: nil, error: "exit 1"),
            ],
            graph: ["a", "b"])

        let stages = run.stages()
        XCTAssertEqual(stages?.map(\.state), [.skipped, .failed])
        XCTAssertEqual(stages?.last?.error, "exit 1")
    }
}
