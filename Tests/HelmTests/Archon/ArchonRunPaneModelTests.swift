import XCTest

@testable import Helm

final class ArchonRunPaneModelTests: XCTestCase {
    @MainActor
    func testRefreshPublishesOrderedCompactNodes() async {
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
            reference: .init(id: "run-1", workflowName: "implement"), client: client)

        await model.refresh()

        XCTAssertEqual(model.run?.nodes, nodes)
        XCTAssertNil(model.failure)
    }

    @MainActor
    func testFailureIsUnavailableRatherThanAnEmptyRun() async {
        let client = FakeArchonClient()
        await client.setFailure(.nonzeroExit(1))
        let model = ArchonRunPaneModel(
            reference: .init(id: "missing", workflowName: "ship"), client: client)

        await model.refresh()

        XCTAssertNil(model.run)
        XCTAssertNotNil(model.failure)
    }

    @MainActor
    func testPollStopsWhenCancelled() async {
        let model = ArchonRunPaneModel(
            reference: .init(id: "r1", workflowName: "ship"), client: FakeArchonClient())
        let poll = Task { await model.poll(every: .milliseconds(1)) }
        try? await Task.sleep(for: .milliseconds(10))
        poll.cancel()
        await poll.value
    }
}
