import XCTest

@testable import Helm

final class ArchonRunPaneModelTests: XCTestCase {
    @MainActor
    func testRefreshPublishesTheRunsNodesInUpstreamOrder() async {
        let nodes = [
            ArchonNode(
                nodeId: "second", state: .running, startedAt: Date(), durationMs: nil,
                outputPreview: nil, error: nil),
            ArchonNode(
                nodeId: "first", state: .failed, startedAt: nil, durationMs: 42, outputPreview: nil,
                error: "boom"),
        ]
        let client = FakeArchonClient(detail: .fixture(nodes: nodes))
        let model = ArchonRunPaneModel(
            reference: .run(id: "run-1", workflowName: "implement"),
            workspacePath: "/tmp/project", client: client)

        await model.refresh()

        XCTAssertEqual(model.content, .run(.fixture(nodes: nodes)))
        XCTAssertNil(model.failure)
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.workspacePaths, ["/tmp/project"])
    }

    /// A status pane is the only route to a finished run now that the rail collapses every
    /// non-running status to a count — so it has to ask Archon for that status, not filter
    /// the twenty rows a bare `workflow runs` happens to return.
    @MainActor
    func testAStatusPaneAsksArchonForThatStatus() async {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [
                .fixture(id: "a", status: "failed"),
                .fixture(id: "b", status: "completed"),
            ]))
        let model = ArchonRunPaneModel(
            reference: .runs(status: "failed"), workspacePath: "/tmp/project", client: client)

        await model.refresh()

        XCTAssertEqual(model.content, .list([.fixture(id: "a", status: "failed")]))
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.statusFilters, ["failed"])
    }

    @MainActor
    func testFailureIsReportedRatherThanAnEmptyRun() async {
        let client = FakeArchonClient()
        await client.setFailure(.notInstalled())
        let model = ArchonRunPaneModel(
            reference: .run(id: "missing", workflowName: "ship"), workspacePath: "/tmp/project",
            client: client)

        await model.refresh()

        XCTAssertNil(model.content)
        XCTAssertNotNil(model.failure)
    }

    @MainActor
    func testWithNoWorkspaceItSaysSoRatherThanCallingTheCLI() async {
        let client = FakeArchonClient()
        let model = ArchonRunPaneModel(
            reference: .run(id: "r1", workflowName: "ship"), workspacePath: nil, client: client)

        await model.refresh()

        XCTAssertEqual(model.failure, ArchonRailModel.noWorkspace)
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.detailRequests, [])
    }

    @MainActor
    func testPollStopsWhenCancelled() async {
        let model = ArchonRunPaneModel(
            reference: .run(id: "r1", workflowName: "ship"), workspacePath: "/tmp/project",
            client: FakeArchonClient())
        let poll = Task { await model.poll(every: .milliseconds(1)) }
        try? await Task.sleep(for: .milliseconds(10))
        poll.cancel()
        await poll.value
    }
}
