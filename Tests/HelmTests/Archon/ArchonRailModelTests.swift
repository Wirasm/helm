import XCTest

@testable import Helm

final class ArchonRailModelTests: XCTestCase {
    @MainActor
    func testVisibilityDefaultsHiddenAndPersists() throws {
        let defaults = try isolatedDefaults("archon-rail-visibility")
        let model = ArchonRailModel(client: FakeArchonClient(), defaults: defaults)
        XCTAssertFalse(model.isVisible)

        model.toggleVisibility()

        XCTAssertTrue(model.isVisible)
        XCTAssertTrue(defaults.bool(forKey: ArchonRailModel.visibilityKey))
    }

    @MainActor
    func testSuccessfulEmptyListIsDistinctFromUnavailable() async throws {
        let defaults = try isolatedDefaults("archon-rail-empty")
        let client = FakeArchonClient()
        let model = ArchonRailModel(client: client, defaults: defaults)

        await model.refresh()
        XCTAssertEqual(model.runs, [])
        XCTAssertNil(model.failure)

        await client.setFailure(.nonzeroExit(127))
        await model.refresh()
        XCTAssertNotNil(model.failure)
    }

    @MainActor
    func testRefreshesNeverOverlap() async throws {
        let defaults = try isolatedDefaults("archon-rail-overlap")
        let client = FakeArchonClient()
        await client.setDelay(.milliseconds(30))
        let model = ArchonRailModel(client: client, defaults: defaults)

        async let first: Void = model.refresh()
        async let second: Void = model.refresh()
        _ = await (first, second)

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.maximumActiveCalls, 1)
        XCTAssertEqual(metrics.activeCalls, 1)
    }

    @MainActor
    func testLaunchValidatesAndRefreshesAfterDetachedAcknowledgement() async throws {
        let defaults = try isolatedDefaults("archon-rail-launch")
        let client = FakeArchonClient(
            workflowList: .init(
                workflows: [.init(name: "ship", description: "Ship it", provider: nil, model: nil)],
                errors: []))
        let model = ArchonRailModel(client: client, defaults: defaults)
        await model.prepareLauncher(workspacePath: "/tmp/project")
        model.input = "implement issue 40"
        model.branch = "issue-40"

        await model.launch(in: "/tmp/project")

        XCTAssertFalse(model.isLauncherOpen)
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.launchRequests, 1)
        XCTAssertEqual(metrics.activeCalls, 1)
    }

    @MainActor
    func testPollStopsWhenCancelled() async throws {
        let model = ArchonRailModel(
            client: FakeArchonClient(), defaults: try isolatedDefaults("archon-rail-poll"))
        let poll = Task { await model.poll(every: .milliseconds(1)) }
        try? await Task.sleep(for: .milliseconds(10))
        poll.cancel()
        await poll.value
    }
}
