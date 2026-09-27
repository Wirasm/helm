import XCTest

@testable import Helm

/// What the Archon drawer added to its model (#382): what a refresh costs, where a live run's
/// dots come from, and the run verbs the rail never had. The rest of the model — the three lists,
/// the inbox, launching and gates — is `ArchonModelTests`.
final class ArchonDrawerModelTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/project")

    /// **One `workflow status` for every live run, and none when nothing is live.** The rail
    /// this replaced asked `workflow get` once per running run on every tick; the drawer's cost
    /// no longer grows with the number of runs.
    @MainActor
    func testARefreshIsOneCallIdleAndTwoWhateverIsLive() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "done", status: "completed")]))
        let model = ArchonModel(
            client: client, defaults: try isolatedDefaults("archon-drawer-idle-cost"))

        await model.refresh(in: workspace)
        var metrics = await client.metrics()
        XCTAssertEqual(metrics.statusCalls, 0, "nothing is live, so nothing but `runs` is asked")

        await client.setRuns(
            .fixture(runs: [
                .fixture(id: "a", status: "running"), .fixture(id: "b", status: "running"),
                .paused(id: "c"),
            ]))
        await model.refresh(in: workspace)
        metrics = await client.metrics()
        XCTAssertEqual(metrics.listCalls, 2)
        XCTAssertEqual(metrics.statusCalls, 1, "three live runs cost one call, not three")
    }

    /// The nodes `workflow status` folded for a live run are what its dots are coloured from.
    @MainActor
    func testALiveRunsDotsComeFromTheStatusCall() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [
                .fixture(
                    id: "a", status: "running", graph: ["plan", "implement", "review"],
                    active: ["implement"])
            ]))
        await client.setStatusRuns([
            .fixture(
                id: "a", status: "running",
                nodes: [
                    .fixture(nodeId: "plan", state: .completed),
                    .fixture(nodeId: "implement", state: .running),
                ])
        ])
        let model = ArchonModel(
            client: client, defaults: try isolatedDefaults("archon-drawer-dots"))

        await model.refresh(in: workspace)

        let run = try XCTUnwrap(model.running.first)
        XCTAssertEqual(
            run.stages(nodes: model.liveNodes["a"])?.map(\.state),
            [.completed, .running, .pending])
    }

    /// A failed `status` call costs the dots their colours and nothing else: the row is on
    /// screen from `runs`, and still shows where the run is from `active_nodes`.
    @MainActor
    func testAFailedStatusCallCostsOnlyTheColours() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [
                .fixture(
                    id: "a", status: "running", graph: ["plan", "implement"], active: ["implement"])
            ]))
        await client.setDetailFailure(.notInstalled())
        let model = ArchonModel(
            client: client, defaults: try isolatedDefaults("archon-drawer-status-failure"))

        await model.refresh(in: workspace)

        let run = try XCTUnwrap(model.running.first)
        XCTAssertNil(model.liveNodes["a"])
        XCTAssertEqual(run.stages(nodes: model.liveNodes["a"])?.map(\.state), [.pending, .running])
    }

    // MARK: - Run verbs

    @MainActor
    func testCancelStopsARunningRunAndSaysWhenArchonRefuses() async throws {
        let running = ArchonRun.fixture(id: "a", status: "running")
        let client = FakeArchonClient(runsResponse: .fixture(runs: [running]))
        let model = ArchonModel(client: client, defaults: try isolatedDefaults("archon-cancel"))

        await model.cancel(running, in: workspace)
        var cancels = await client.cancels()
        XCTAssertEqual(cancels, ["a"])
        XCTAssertNil(model.actionFailure)

        await client.setCancellation(.fixture(ok: false, action: "cancel", error: "not running"))
        await model.cancel(running, in: workspace)
        XCTAssertEqual(model.actionFailure, "Archon refused to cancel this run: not running")

        await model.cancel(.fixture(id: "d", status: "completed"), in: workspace)
        cancels = await client.cancels()
        XCTAssertEqual(cancels, ["a", "a"], "a finished run is never sent to cancel")
    }

    @MainActor
    func testResumeRestartsAFailedRunAndNothingElse() async throws {
        let failed = ArchonRun.fixture(id: "f", status: "failed")
        let client = FakeArchonClient(runsResponse: .fixture(runs: [failed]))
        let model = ArchonModel(client: client, defaults: try isolatedDefaults("archon-resume"))

        await model.resume(failed, in: workspace)
        await model.resume(.fixture(id: "r", status: "running"), in: workspace)

        let resumes = await client.gateCalls().resumes
        XCTAssertEqual(resumes, ["f"])
        XCTAssertNil(model.actionFailure)
    }

    /// ⌥↑ / ⌥↓ walk the workflow list, loading it the first time, and wrap at either end.
    @MainActor
    func testTheWorkflowIsPickedFromTheKeyboard() async throws {
        let client = FakeArchonClient(
            workflowList: .init(
                workflows: ["plan", "deliver", "review"].map {
                    ArchonWorkflow(name: $0, description: "", provider: nil, model: nil)
                }, errors: []))
        let model = ArchonModel(client: client, defaults: try isolatedDefaults("archon-cycle"))

        await model.cycleWorkflow(by: 1, in: workspace)
        XCTAssertEqual(model.config.workflow, "deliver", "the first load seeds plan, then steps")
        XCTAssertFalse(model.isConfigOpen, "picking from the keyboard opens no popover")
        await model.cycleWorkflow(by: 1, in: workspace)
        await model.cycleWorkflow(by: 1, in: workspace)
        XCTAssertEqual(model.config.workflow, "plan")
        await model.cycleWorkflow(by: -1, in: workspace)
        XCTAssertEqual(model.config.workflow, "review")
    }
}
