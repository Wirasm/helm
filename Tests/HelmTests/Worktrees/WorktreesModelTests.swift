import HelmWire
import XCTest

@testable import Helm

/// The Worktrees drawer's model (#382). The rail's per-workspace tests (collapsed does no I/O,
/// a workspace switch drops the old answer) left with the rail: the drawer lists the machine,
/// not a workspace, and has no collapsed state. Its cleanup tests became the removal tests
/// below, per repository.
@MainActor
final class WorktreesModelTests: XCTestCase {
    private let app = GitCommonDir("/work/app/.git")
    private let lib = GitCommonDir("/work/lib/.git")
    private let solo = GitCommonDir("/work/solo/.git")

    private func model(
        _ client: FakeWorktreeClient, found: [BenchGitRepository]? = nil
    ) -> WorktreesModel {
        let found =
            found ?? [
                .init(commonDir: app, isWorkspace: true),
                .init(commonDir: lib, isWorkspace: false),
                .init(commonDir: solo, isWorkspace: false),
            ]
        return WorktreesModel(worktreeClient: client, discover: { _ in found })
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
            BenchGitRepository(commonDir: GitCommonDir("/r\($0)/.git"), isWorkspace: false)
        }
        let model = model(client, found: found)

        await model.refresh(workspaces: [])

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.listCalls, 14)
        XCTAssertEqual(metrics.maximumListCalls, WorktreesModel.concurrentRepositories)
        XCTAssertEqual(
            model.repos.map(\.id), found.map { GitCommonDir($0.commonDir) },
            "published in discovery order")
    }

    /// `git status` of a lone main checkout is read only for a workspace's repository: every
    /// other repository with only its main checkout is not listed, so its status is never shown.
    func testOnlyAWorkspacesRepositoryHasItsLoneCheckoutsStatusRead() async {
        let client = FakeWorktreeClient(response: [main("/work/x")])
        let model = model(client)

        await model.refresh(workspaces: [])

        let asked = await client.loneStatusAsked
        let repositories = await client.metrics().repositories
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: zip(repositories, asked)),
            [app: true, lib: false, solo: false])
    }

    /// Hidden mid-refresh: the reads running are cancelled and no new ones start, so the
    /// refresh ends at once and the next showing's refresh is not dropped behind it.
    func testAHiddenDrawersRefreshStartsNoMoreReads() async throws {
        let client = FakeWorktreeClient(response: [main("/work/x")])
        await client.setDelay(.seconds(30))
        let found = (0..<14).map {
            BenchGitRepository(commonDir: GitCommonDir("/r\($0)/.git"), isWorkspace: false)
        }
        let model = model(client, found: found)

        let refresh = Task { await model.refresh(workspaces: []) }
        for _ in 0..<500
        where await client.metrics().listCalls < WorktreesModel.concurrentRepositories {
            try await Task.sleep(for: .milliseconds(10))
        }
        refresh.cancel()
        await refresh.value

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.listCalls, WorktreesModel.concurrentRepositories)
        XCTAssertFalse(model.isRefreshing, "done, so the next showing refreshes")
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
        var found: [BenchGitRepository] = [
            .init(commonDir: app, isWorkspace: false), .init(commonDir: lib, isWorkspace: false),
        ]
        let box = FoundBox(found)
        let model = WorktreesModel(
            worktreeClient: client, discover: { _ in box.value })
        await model.refresh(workspaces: [])
        XCTAssertEqual(model.repos.map(\.id), [app, lib])

        found.removeFirst()
        box.value = found
        await model.refresh(workspaces: [])

        XCTAssertEqual(model.repos.map(\.id), [lib])
    }

    // MARK: - Creating

    func testANewWorktreeIsMadeFromTheMainCheckoutAndListed() async {
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app")], for: app)
        let model = model(client)
        await model.refresh(workspaces: [])

        let path = await model.create(branch: " feat/new ", in: app)

        XCTAssertEqual(path, "/work/app/.worktrees/feat-new")
        let requests = await client.createRequests
        XCTAssertEqual(requests.map(\.branch), ["feat/new"], "trimmed, never blank")
        XCTAssertEqual(requests.map(\.main), ["/work/app"])
        XCTAssertEqual(
            model.repos.first { $0.id == app }?.worktrees.map(\.id),
            ["/work/app", "/work/app/.worktrees/feat-new"], "read again, so it is on the list")
    }

    func testAFailedCreateSaysWhyAndABlankBranchAsksNothing() async {
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app")], for: app)
        let failure = WorktreeCLIError(
            command: "git worktree add", reason: .nonzeroExit(status: 128, stderr: "in use"))
        await client.setCreateFailure(failure)
        let model = model(client)
        await model.refresh(workspaces: [])

        let blank = await model.create(branch: "  ", in: app)
        XCTAssertNil(blank)
        let requestsAfterBlank = await client.createRequests
        XCTAssertTrue(requestsAfterBlank.isEmpty)

        let path = await model.create(branch: "x", in: app)
        XCTAssertNil(path)
        XCTAssertEqual(model.createFailure, failure.localizedDescription)
    }

    // MARK: - Removing (#141), per repository

    /// Nothing goes before the operator confirms, the confirmation carries what git says is
    /// lost, and the removal is handed that same loss.
    func testADeleteAsksWithTheLossFirstAndRemovesOnlyOnConfirm() async {
        let row = Worktree.fixture(
            path: "/work/app-wip", branch: "feat/wip", mergedState: .unmerged)
        let loss = WorktreeLoss(
            uncommittedFiles: 2, unmergedCommits: 3, branch: "feat/wip",
            defaultBranch: "refs/remotes/origin/main")
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app"), row], for: app)
        await client.setLoss(loss, for: row.id)
        let model = model(client)
        await model.refresh(workspaces: [])

        await model.requestDelete(of: row)
        XCTAssertEqual(model.confirmation, .delete(path: row.id, loss: loss))
        var removed = await client.removeRequests
        XCTAssertTrue(removed.isEmpty, "nothing before the operator confirms")

        await model.confirm()
        removed = await client.removeRequests
        XCTAssertEqual(removed.map(\.path), [row.id])
        XCTAssertEqual(removed.map(\.repository), [app])
        let handed = await client.removeLosses
        XCTAssertEqual(handed, [loss])
        XCTAssertEqual(model.repos.first { $0.id == app }?.worktrees.count, 1)
    }

    /// An agent writing into the worktree while the dialog is open changes the loss; nothing the
    /// operator was not told about goes, and he is asked again with what is there now.
    func testALossThatChangedWhileAskingIsAskedAgainNotRemoved() async {
        let row = Worktree.fixture(path: "/work/app-busy", mergedState: .unmerged)
        func loss(_ files: Int) -> WorktreeLoss {
            WorktreeLoss(
                uncommittedFiles: files, unmergedCommits: 1, branch: "feature/one",
                defaultBranch: "refs/remotes/origin/main")
        }
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app"), row], for: app)
        await client.setLoss(loss(1), for: row.id)
        let model = model(client)
        await model.refresh(workspaces: [])

        await model.requestDelete(of: row)
        await client.setLoss(loss(6), for: row.id)
        await model.confirm()

        let removed = await client.removeRequests
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(model.confirmation, .delete(path: row.id, loss: loss(6)))
    }

    func testArchonsRefusalKeepsEveryReasonAndDropsItsForceAdvice() {
        let said = """
              Blocked: archon/task-2
                ✗ uncommitted changes in worktree
                ✗ 2 commit(s) not pushed to remote
                ✗ open PR #12 — "x"
              Use --force to override.

            Complete: 0 completed, 1 failed, 0 not found
            """
        XCTAssertEqual(
            WorktreesModel.refusal(in: said),
            "Blocked: archon/task-2 ✗ uncommitted changes in worktree ✗ 2 commit(s) not pushed "
                + "to remote ✗ open PR #12 — \"x\"")
    }

    func testCancellingRemovesNothing() async {
        let row = Worktree.fixture(path: "/work/app-x")
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app"), row], for: app)
        let model = model(client)
        await model.refresh(workspaces: [])

        await model.requestDelete(of: row)
        model.cancelConfirmation()
        await model.confirm()

        let removed = await client.removeRequests
        XCTAssertTrue(removed.isEmpty)
    }

    func testTheMainCheckoutALockedOneAndABareRepositoryCannotBeAskedAbout() async {
        let rows = [
            main("/main"), Worktree.fixture(path: "/locked", locked: true),
            Worktree.fixture(path: "/bare", bare: true),
        ]
        let client = FakeWorktreeClient()
        await client.setResponse(rows, for: app)
        let model = model(client)
        await model.refresh(workspaces: [])

        for row in rows { await model.requestDelete(of: row) }

        XCTAssertNil(model.confirmation)
        let reads = await client.lossReadCount()
        XCTAssertEqual(reads, 0)
    }

    /// An Archon worktree goes through `archon complete` in its own Archon home, run from the
    /// repository's main checkout; git's own removal is never used on it.
    func testAnArchonWorktreeGoesToArchonInItsOwnHome() async {
        let path = "/h/.archon-demo/workspaces/o/app/worktrees/archon/task-1"
        let row = Worktree.fixture(path: path, branch: "archon/task-1")
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app"), row], for: app)
        let model = model(client)
        await model.refresh(workspaces: [])

        await model.requestDelete(of: row)
        await model.confirm()

        let requests = await client.archonRequests
        XCTAssertEqual(requests.map(\.branch), ["archon/task-1"])
        XCTAssertEqual(requests.map(\.home), ["/h/.archon-demo"])
        XCTAssertEqual(requests.map(\.main), ["/work/app"])
        let removed = await client.removeRequests
        XCTAssertTrue(removed.isEmpty)
        XCTAssertNil(model.actionFailures[path])
    }

    /// `archon complete` exits 0 when it refuses, so its success is read from git: a worktree
    /// still listed afterwards is a failure, in Archon's own words.
    func testAnArchonRefusalIsSeenInGitAndShownInArchonsWords() async {
        let path = "/h/.archon/workspaces/o/app/worktrees/archon/task-2"
        let row = Worktree.fixture(path: path, branch: "archon/task-2")
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app"), row], for: app)
        await client.setArchon(
            said: "  Blocked: archon/task-2\n    ✗ 2 commit(s) not pushed to remote\n"
                + "  Use --force to override.\n\nComplete: 0 completed, 1 failed, 0 not found",
            keeps: true)
        let model = model(client)
        await model.refresh(workspaces: [])

        await model.requestDelete(of: row)
        await model.confirm()

        let failure = try? XCTUnwrap(model.actionFailures[path])
        XCTAssertTrue(failure?.contains("not pushed to remote") == true, failure ?? "no failure")
    }

    /// Clean-merged is one repository's merged, clean worktrees, each read again just before it
    /// goes; one that has work in it by then is skipped and says so.
    func testCleanMergedRereadsEachAndSkipsOneThatGainedWork() async {
        let quiet = Worktree.fixture(path: "/work/a", branch: "fix/a")
        let busy = Worktree.fixture(path: "/work/b", branch: "fix/b")
        let unmerged = Worktree.fixture(path: "/work/c", mergedState: .unmerged)
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app"), quiet, busy, unmerged], for: app)
        await client.setResponse([main("/work/lib"), .fixture(path: "/work/lib-d")], for: lib)
        await client.setLoss(
            WorktreeLoss(
                uncommittedFiles: 1, unmergedCommits: 0, branch: "fix/b",
                defaultBranch: "refs/remotes/origin/main"), for: busy.id)
        let model = model(client)
        await model.refresh(workspaces: [])

        model.requestCleanMerged(in: app)
        XCTAssertEqual(model.confirmation, .cleanMerged(repo: app, paths: ["/work/a", "/work/b"]))
        await model.confirm()

        let removed = await client.removeRequests
        XCTAssertEqual(removed.map(\.path), ["/work/a"], "never another repository's row")
        XCTAssertNotNil(model.actionFailures["/work/b"])
    }

    /// After a removal only that repository is read again, not the machine.
    func testARemovalRereadsOnlyItsRepository() async {
        let row = Worktree.fixture(path: "/work/app-git")
        let client = FakeWorktreeClient()
        await client.setResponse([main("/work/app"), row], for: app)
        let model = model(client)
        await model.refresh(workspaces: [])

        await model.requestDelete(of: row)
        await model.confirm()

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.repositories.suffix(1), [app])
        XCTAssertEqual(metrics.listCalls, 4)
    }
}

/// A discovery answer a test changes between refreshes.
private final class FoundBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BenchGitRepository]
    init(_ value: [BenchGitRepository]) { stored = value }
    var value: [BenchGitRepository] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension BenchGitRepository {
    init(commonDir: GitCommonDir, isWorkspace: Bool) {
        self.init(commonDir: commonDir.path, isWorkspace: isWorkspace)
    }
}
