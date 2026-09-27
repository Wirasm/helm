import XCTest

@testable import Helm

/// The Worktrees drawer's model (#382). The rail's per-workspace tests (collapsed does no I/O,
/// a workspace switch drops the old answer) left with the rail: the drawer lists the machine,
/// not a workspace, and has no collapsed state. Its cleanup tests are kept, per repository.
@MainActor
final class WorktreesModelTests: XCTestCase {
    private let app = "/work/app/.git"
    private let lib = "/work/lib/.git"
    private let solo = "/work/solo/.git"

    private func model(
        _ client: FakeWorktreeClient, archon: FakeArchonClient = FakeArchonClient(),
        found: [WorktreeDiscovery.Found]? = nil
    ) -> WorktreesModel {
        let found =
            found ?? [
                .init(commonDir: app, isWorkspace: true),
                .init(commonDir: lib, isWorkspace: false),
                .init(commonDir: solo, isWorkspace: false),
            ]
        return WorktreesModel(
            worktreeClient: client, archonClient: archon, discover: { _ in found })
    }

    private func main(_ path: String) -> Worktree {
        .fixture(path: path, branch: "main", isMain: true)
    }

    // MARK: - Reading

    /// Every repository found is read once, in discovery order. A repository with only its main
    /// checkout is read but not listed unless a workspace is in it, and the drawer says how many
    /// it left out.
    func testARefreshReadsEveryRepositoryAndListsTheOnesWithWorktrees() async {
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app")], for: app)
        await client.setResponse([main("/work/lib"), .fixture(path: "/work/lib-fix")], for: lib)
        await client.setResponse([main("/work/solo")], for: solo)
        let model = model(client)

        await model.refresh(workspaces: ["/work/app"])

        XCTAssertEqual(model.repos.map(\.id), [app, lib, solo])
        XCTAssertEqual(
            model.listed.map(\.id), [app, lib],
            "the workspace's repository is listed alone; solo, with only its main, is not")
        XCTAssertEqual(model.unlistedCount, 1)
        let metrics = await client.metrics()
        XCTAssertEqual(Set(metrics.repositories), [app, lib, solo])
        XCTAssertEqual(metrics.listCalls, 3)
    }

    /// Repositories are read a few at a time, never all at once and never one by one.
    func testRepositoriesAreReadAtMostSixAtATime() async {
        let client = FakeWorktreeClient(response: [main("/work/x")])
        await client.setDelay(.milliseconds(30))
        let found = (0..<14).map {
            WorktreeDiscovery.Found(commonDir: "/r\($0)/.git", isWorkspace: false)
        }
        let model = model(client, found: found)

        await model.refresh(workspaces: [])

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.listCalls, 14)
        XCTAssertEqual(metrics.maximumListCalls, WorktreesModel.concurrentRepositories)
        XCTAssertEqual(
            model.repos.map(\.id), found.map(\.commonDir), "published in discovery order")
    }

    /// A refresh asked for while one runs is dropped: the running one answers the same question.
    func testARefreshWhileOneRunsIsDropped() async {
        let client = FakeWorktreeClient(response: [main("/work/x")])
        await client.setDelay(.milliseconds(30))
        let model = model(client)

        async let first: Void = model.refresh(workspaces: [])
        async let second: Void = model.refresh(workspaces: [])
        _ = await (first, second)

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.listCalls, 3, "one read per repository, not two")
    }

    func testAFailedRepositoryKeepsItsLastRowsAndSaysWhy() async {
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/lib"), .fixture(path: "/work/lib-fix")], for: lib)
        let model = model(client)
        await model.refresh(workspaces: [])
        let failure = WorktreeCLIError(
            command: "git worktree list", reason: .nonzeroExit(status: 128, stderr: "gone"))
        await client.setListFailure(failure, for: lib)

        await model.refresh(workspaces: [])

        XCTAssertEqual(model.repos.first { $0.id == lib }?.worktrees.count, 2)
        XCTAssertEqual(model.refreshFailures[lib], failure.localizedDescription)
        XCTAssertNil(model.refreshFailures[app], "one repository's failure is its own")
    }

    func testARepositoryNoLongerFoundLeavesTheList() async {
        let client = FakeWorktreeClient(response: [main("/work/x"), .fixture()])
        var found: [WorktreeDiscovery.Found] = [
            .init(commonDir: app, isWorkspace: false), .init(commonDir: lib, isWorkspace: false),
        ]
        let box = FoundBox(found)
        let model = WorktreesModel(
            worktreeClient: client, archonClient: FakeArchonClient(), discover: { _ in box.value })
        await model.refresh(workspaces: [])
        XCTAssertEqual(model.repos.map(\.id), [app, lib])

        found.removeFirst()
        box.value = found
        await model.refresh(workspaces: [])

        XCTAssertEqual(model.repos.map(\.id), [lib])
    }

    // MARK: - Cleanup (#141), per repository

    func testConfirmationGateAndOwnerRoutingUseExactRequests() async {
        let gitRow = Worktree.fixture(path: "/work/app-git", branch: "feature/one")
        let archonRow = Worktree.fixture(path: "/work/app-archon", branch: "archon/task-141")
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app"), gitRow, archonRow], for: app)
        let archon = FakeArchonClient()
        let model = model(client, archon: archon)
        await model.refresh(workspaces: [])

        model.requestCleanup(of: gitRow)
        var metrics = await client.metrics()
        XCTAssertEqual(metrics.removeRequests.count, 0, "nothing before the operator confirms")
        await model.confirm()
        metrics = await client.metrics()
        XCTAssertEqual(metrics.removeRequests.map(\.path), ["/work/app-git"])
        XCTAssertEqual(metrics.removeRequests.map(\.repository), [app])

        model.requestCleanup(of: archonRow)
        await model.confirm()
        let completions = await archon.completions()
        XCTAssertEqual(completions.map(\.branch), ["archon/task-141"])
        XCTAssertEqual(
            completions.map(\.workspacePath), [WorkspacePath("/work/app")],
            "archon runs in the repository's main checkout")
    }

    func testIneligibleRowsCannotReachEitherProcess() async {
        let rows = [
            main("/main"),
            Worktree.fixture(path: "/detached", branch: nil, detached: true),
            Worktree.fixture(path: "/locked", locked: true),
            Worktree.fixture(path: "/prunable", prunable: true),
            Worktree.fixture(path: "/unmerged", mergedState: .unmerged),
            Worktree.fixture(path: "/unknown", mergedState: .unknown),
        ]
        let client = FakeWorktreeClient()
        await client.setResponse(rows, for: app)
        let archon = FakeArchonClient()
        let model = model(client, archon: archon)
        await model.refresh(workspaces: [])

        for row in rows { model.requestCleanup(of: row) }
        model.requestCleanAll(in: app)
        await model.confirm()

        XCTAssertNil(model.confirmation)
        let metrics = await client.metrics()
        let completions = await archon.completions()
        XCTAssertEqual(metrics.removeRequests.count, 0)
        XCTAssertEqual(completions.count, 0)
    }

    /// Clean All is one repository's merged worktrees, and one failure does not stop the rest.
    func testCleanAllContinuesAfterAnArchonFailureAndKeepsItVisible() async {
        let archonRow = Worktree.fixture(path: "/work/a", branch: "archon/task-141")
        let gitRow = Worktree.fixture(path: "/work/b", branch: "feature/two")
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app"), archonRow, gitRow], for: app)
        await client.setResponse([main("/work/lib"), .fixture(path: "/work/lib-c")], for: lib)
        let archon = FakeArchonClient()
        await archon.setCompleteFailure(
            ArchonCLIError(command: "archon complete", reason: .actionRejected("Not found")))
        let model = model(client, archon: archon)
        await model.refresh(workspaces: [])

        model.requestCleanAll(in: app)
        await model.confirm()

        let completions = await archon.completions()
        let metrics = await client.metrics()
        XCTAssertEqual(completions.map(\.branch), ["archon/task-141"])
        XCTAssertEqual(
            metrics.removeRequests.map(\.path), ["/work/b"], "never another repository's row")
        XCTAssertNotNil(model.actionFailures["/work/a"])
        XCTAssertFalse(model.isCleaningAll)
    }

    /// After a cleanup only that repository is read again, not the machine.
    func testACleanupRereadsOnlyItsRepository() async {
        let row = Worktree.fixture(path: "/work/app-git")
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app"), row], for: app)
        let model = model(client)
        await model.refresh(workspaces: [])
        await client.setResponse([main("/work/app")], for: app)

        model.requestCleanup(of: row)
        await model.confirm()

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.repositories.suffix(1), [app])
        XCTAssertEqual(metrics.listCalls, 4)
        XCTAssertEqual(model.repos.first { $0.id == app }?.worktrees.count, 1)
    }
}

/// A discovery answer a test changes between refreshes.
private final class FoundBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [WorktreeDiscovery.Found]
    init(_ value: [WorktreeDiscovery.Found]) { stored = value }
    var value: [WorktreeDiscovery.Found] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
