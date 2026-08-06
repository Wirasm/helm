import XCTest

@testable import Helm

final class WorktreesRailModelTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/project")

    @MainActor
    func testCollapsedDoesNoIOAndExpansionListsOnce() async {
        let worktrees = FakeWorktreeClient(response: [.fixture()])
        let model = WorktreesRailModel(
            worktreeClient: worktrees, archonClient: FakeArchonClient())

        await model.workspaceChanged(to: workspace)
        var metrics = await worktrees.metrics()
        XCTAssertEqual(metrics.listCalls, 0)

        await model.setExpanded(true, in: workspace)
        metrics = await worktrees.metrics()
        XCTAssertEqual(metrics.listCalls, 1)
        XCTAssertEqual(model.rows.map(\.id), ["/tmp/project-linked"])
    }

    @MainActor
    func testNilWorkspaceClearsRowsWithoutAnotherCall() async {
        let worktrees = FakeWorktreeClient(response: [.fixture()])
        let model = WorktreesRailModel(
            worktreeClient: worktrees, archonClient: FakeArchonClient())
        await model.setExpanded(true, in: workspace)

        await model.workspaceChanged(to: nil)

        XCTAssertTrue(model.rows.isEmpty)
        let metrics = await worktrees.metrics()
        XCTAssertEqual(metrics.listCalls, 1)
    }

    @MainActor
    func testReopeningAndOpeningAfterACollapsedWorkspaceSwitchRefreshOnDemand() async {
        let worktrees = FakeWorktreeClient(response: [.fixture(path: "/first")])
        let model = WorktreesRailModel(
            worktreeClient: worktrees, archonClient: FakeArchonClient())
        await model.setExpanded(true, in: workspace)
        await model.setExpanded(false, in: workspace)
        await worktrees.setResponse([.fixture(path: "/reopened")])

        await model.setExpanded(true, in: workspace)
        XCTAssertEqual(model.rows.map(\.id), ["/reopened"])

        await model.setExpanded(false, in: workspace)
        await worktrees.setResponse(
            [.fixture(path: "/other")], for: WorkspacePath("/other-workspace"))
        await model.workspaceChanged(to: WorkspacePath("/other-workspace"))
        XCTAssertTrue(model.rows.isEmpty)
        await model.setExpanded(true, in: WorkspacePath("/other-workspace"))

        XCTAssertEqual(model.rows.map(\.id), ["/other"])
        let metrics = await worktrees.metrics()
        XCTAssertEqual(metrics.listCalls, 3)
    }

    @MainActor
    func testOldWorkspaceCannotPublishAfterAWorkspaceSwitch() async {
        let worktrees = FakeWorktreeClient()
        await worktrees.setResponse([.fixture(path: "/old")], for: WorkspacePath("/old-workspace"))
        await worktrees.setResponse([.fixture(path: "/new")], for: WorkspacePath("/new-workspace"))
        await worktrees.setDelay(.milliseconds(25))
        let model = WorktreesRailModel(
            worktreeClient: worktrees, archonClient: FakeArchonClient())

        let old = Task { await model.setExpanded(true, in: WorkspacePath("/old-workspace")) }
        try? await Task.sleep(for: .milliseconds(5))
        await model.workspaceChanged(to: WorkspacePath("/new-workspace"))
        await old.value

        XCTAssertEqual(model.rows.map(\.id), ["/new"])
    }

    @MainActor
    func testRefreshesForOneWorkspaceNeverOverlap() async {
        let worktrees = FakeWorktreeClient()
        await worktrees.setDelay(.milliseconds(25))
        let model = WorktreesRailModel(
            worktreeClient: worktrees, archonClient: FakeArchonClient())
        await model.setExpanded(true, in: workspace)
        let workspace = self.workspace

        async let first: Void = model.refresh(in: workspace)
        async let second: Void = model.refresh(in: workspace)
        _ = await (first, second)

        let metrics = await worktrees.metrics()
        XCTAssertEqual(metrics.maximumListCalls, 1)
    }

    @MainActor
    func testListFailurePreservesLastKnownRows() async {
        let failure = WorktreeCLIError(
            command: "git worktree list", reason: .nonzeroExit(status: 1, stderr: "gone"))
        let worktrees = FakeWorktreeClient(response: [.fixture()])
        let model = WorktreesRailModel(
            worktreeClient: worktrees, archonClient: FakeArchonClient())
        await model.setExpanded(true, in: workspace)
        await worktrees.setListFailure(failure)

        await model.refresh(in: workspace)

        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.refreshFailure, failure.localizedDescription)
    }

    @MainActor
    func testConfirmationGateAndOwnerRoutingUseExactRequests() async {
        let gitRow = Worktree.fixture(path: "/tmp/git", branch: "feature/one")
        let archonRow = Worktree.fixture(path: "/tmp/archon", branch: "archon/task-141")
        let worktrees = FakeWorktreeClient(response: [gitRow, archonRow])
        let archon = FakeArchonClient()
        let model = WorktreesRailModel(worktreeClient: worktrees, archonClient: archon)
        await model.setExpanded(true, in: workspace)

        model.requestCleanup(of: gitRow)
        var metrics = await worktrees.metrics()
        XCTAssertEqual(metrics.removeRequests.count, 0)
        await model.confirm(in: workspace)
        metrics = await worktrees.metrics()
        XCTAssertEqual(metrics.removeRequests.map(\.path), ["/tmp/git"])

        model.requestCleanup(of: archonRow)
        await model.confirm(in: workspace)
        let completions = await archon.completions()
        XCTAssertEqual(completions.map(\.branch), ["archon/task-141"])
        XCTAssertEqual(completions.map(\.workspacePath), [workspace])
    }

    @MainActor
    func testIneligibleRowsCannotReachEitherProcess() async {
        let rows = [
            Worktree.fixture(path: "/main", isMain: true),
            Worktree.fixture(path: "/detached", branch: nil, detached: true),
            Worktree.fixture(path: "/locked", locked: true),
            Worktree.fixture(path: "/prunable", prunable: true),
            Worktree.fixture(path: "/unmerged", mergedState: .unmerged),
            Worktree.fixture(path: "/unknown", mergedState: .unknown),
        ]
        let worktrees = FakeWorktreeClient(response: rows)
        let archon = FakeArchonClient()
        let model = WorktreesRailModel(worktreeClient: worktrees, archonClient: archon)
        await model.setExpanded(true, in: workspace)

        for row in rows { model.requestCleanup(of: row) }
        await model.confirm(in: workspace)

        XCTAssertNil(model.confirmation)
        let metrics = await worktrees.metrics()
        let completions = await archon.completions()
        XCTAssertEqual(metrics.removeRequests.count, 0)
        XCTAssertEqual(completions.count, 0)
        XCTAssertTrue(model.cleanableRows.isEmpty)
    }

    @MainActor
    func testCleanAllContinuesAfterAnArchonFailureAndKeepsItVisible() async {
        let archonRow = Worktree.fixture(path: "/tmp/a", branch: "archon/task-141")
        let gitRow = Worktree.fixture(path: "/tmp/b", branch: "feature/two")
        let worktrees = FakeWorktreeClient(response: [archonRow, gitRow])
        let archon = FakeArchonClient()
        await archon.setCompleteFailure(
            ArchonCLIError(command: "archon complete", reason: .actionRejected("Not found")))
        let model = WorktreesRailModel(worktreeClient: worktrees, archonClient: archon)
        await model.setExpanded(true, in: workspace)

        model.requestCleanAll()
        await model.confirm(in: workspace)

        let completions = await archon.completions()
        let metrics = await worktrees.metrics()
        XCTAssertEqual(completions.map(\.branch), ["archon/task-141"])
        XCTAssertEqual(metrics.removeRequests.map(\.path), ["/tmp/b"])
        XCTAssertNotNil(model.actionFailures["/tmp/a"])
        XCTAssertFalse(model.isCleaningAll)
    }
}
