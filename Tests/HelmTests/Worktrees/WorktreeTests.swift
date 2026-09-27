import XCTest

@testable import Helm

final class WorktreeTests: XCTestCase {
    func testParsesEveryPorcelainRecordAndPreservesUnsupportedFields() throws {
        let records = try WorktreeCLI.parsePorcelain(
            """
            worktree /repo
            HEAD aaaa
            branch refs/heads/development

            worktree /repo/detached
            HEAD bbbb
            detached
            locked reason here
            future-field value

            worktree /repo/prunable
            HEAD cccc
            prunable gitdir file points to non-existent location

            worktree /repo/bare
            bare

            """)

        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records[0].branchName, "development")
        XCTAssertTrue(records[1].isDetached)
        XCTAssertTrue(records[1].isLocked)
        XCTAssertEqual(records[1].unrecognisedFields, ["future-field value"])
        XCTAssertNil(records[1].branch)
        XCTAssertTrue(records[2].isPrunable)
        XCTAssertTrue(records[3].isBare)
    }

    func testRejectsPorcelainRecordWithoutAWorktreePath() {
        XCTAssertThrowsError(try WorktreeCLI.parsePorcelain("HEAD deadbeef\n")) { error in
            XCTAssertEqual(
                error as? WorktreeCLIError,
                WorktreeCLIError(
                    command: "git worktree list --porcelain",
                    reason: .malformedOutput("record has no worktree path")))
        }
    }

    func testRecognisesOnlyDocumentedArchonBranchFamilies() {
        for branch in [
            "archon/task-123", "archon/issue-141", "archon/pr-9", "archon/review-9",
            "archon/thread-abc",
        ] {
            XCTAssertEqual(
                WorktreeOwner.of(path: "/p/x", branch: branch), .archon(home: nil), branch)
        }
        XCTAssertEqual(WorktreeOwner.of(path: "/p/x", branch: "feature/archon-task"), .git)
        XCTAssertEqual(WorktreeOwner.of(path: "/p/x", branch: nil), .git)
    }

    /// A worktree under an Archon home is Archon's whatever its branch is called, and the home is
    /// the database `archon complete` must read: `~/.archon-helm-quick-deliver` is not `~/.archon`.
    func testAWorktreeUnderAnArchonHomeIsArchonsAndNamesThatHome() {
        XCTAssertEqual(
            WorktreeOwner.of(
                path: "/Users/o/.archon-helm-quick-deliver/workspaces/Wirasm/helm/worktrees/fix/x",
                branch: "fix/x"),
            .archon(home: "/Users/o/.archon-helm-quick-deliver"))
        XCTAssertEqual(
            WorktreeOwner.of(
                path: "/Users/o/.archon/workspaces/a/b/worktrees/archon/t", branch: nil),
            .archon(home: "/Users/o/.archon"))
        XCTAssertEqual(
            WorktreeOwner.of(path: "/Users/o/Projects/.archon-notes/x", branch: "main"), .git,
            "an .archon folder without workspaces under it is not an Archon home")
        XCTAssertEqual(
            WorktreeOwner.of(
                path: "/Users/o/.archon/workspaces/a/b/source-feat-x", branch: "feat/x"),
            .git, "beside Archon's own clone: Archon has no record of it")
        XCTAssertEqual(
            WorktreeOwner.of(
                path: "/Users/o/.archon/workspaces/a/b/source/.worktrees/feat-x", branch: "feat/x"),
            .git, "inside Archon's clone, likewise")
    }

    /// Removable is about whether git or Archon can take it at all, not about what it loses:
    /// unmerged and dirty worktrees are removable, behind a confirmation that names the loss.
    func testRemovableIsEveryLinkedWorktreeButMainBareAndLocked() {
        XCTAssertTrue(Worktree.fixture().isRemovable)
        XCTAssertTrue(Worktree.fixture(mergedState: .unmerged).isRemovable)
        XCTAssertTrue(Worktree.fixture(exists: false, prunable: true).isRemovable)
        XCTAssertTrue(Worktree.fixture(branch: nil, detached: true).isRemovable)
        XCTAssertFalse(Worktree.fixture(isMain: true).isRemovable)
        XCTAssertFalse(Worktree.fixture(bare: true).isRemovable)
        XCTAssertFalse(Worktree.fixture(locked: true).isRemovable)
        XCTAssertFalse(
            Worktree.fixture(path: "/h/.archon/workspaces/a/b/worktrees/x", branch: nil)
                .isRemovable,
            "archon complete is asked about a branch")
    }

    /// `⇧D` only takes what loses nothing, as far as the last refresh knows.
    func testMergedAndCleanNeedsBothAndAKnownCleanStatus() {
        let dirty = WorktreeStatus(isDirty: true, tracking: nil, lastCommitAt: nil)
        XCTAssertTrue(Worktree.fixture().isMergedAndClean)
        XCTAssertFalse(Worktree.fixture(mergedState: .unmerged).isMergedAndClean)
        XCTAssertFalse(Worktree.fixture(mergedState: .unknown).isMergedAndClean)
        XCTAssertFalse(Worktree.fixture(status: dirty).isMergedAndClean)
        XCTAssertFalse(Worktree.fixture(status: .unknown).isMergedAndClean)
        XCTAssertFalse(Worktree.fixture(exists: false).isMergedAndClean)
        XCTAssertFalse(Worktree.fixture(isMain: true).isMergedAndClean)
    }

    /// The confirmation's words: every loss named, an unknown never read as nothing, and a
    /// branch deleted only when nothing on it is lost.
    func testTheLossNamesEveryThingThatGoes() {
        let base = "refs/remotes/origin/main"
        let nothing = WorktreeLoss(
            uncommittedFiles: 0, unmergedCommits: 0, branch: "fix/x", defaultBranch: base)
        XCTAssertTrue(nothing.losesNothing)
        XCTAssertTrue(nothing.deletesBranch)
        XCTAssertEqual(nothing.clauses, [])

        let both = WorktreeLoss(
            uncommittedFiles: 3, unmergedCommits: 1, branch: "feat/y", defaultBranch: base)
        XCTAssertFalse(both.losesNothing)
        XCTAssertFalse(both.deletesBranch, "an unmerged branch is kept")
        XCTAssertEqual(
            both.clauses,
            ["3 uncommitted files", "1 commit on feat/y not on origin/main (the branch is kept)"])

        let unknown = WorktreeLoss(
            uncommittedFiles: nil, unmergedCommits: nil, branch: "z", defaultBranch: nil)
        XCTAssertFalse(unknown.losesNothing)
        XCTAssertFalse(unknown.deletesBranch)
        XCTAssertEqual(unknown.clauses.count, 2)

        let detached = WorktreeLoss(
            uncommittedFiles: 0, unmergedCommits: 2, branch: nil, defaultBranch: base)
        XCTAssertEqual(
            detached.clauses, ["2 detached commits not on origin/main, reachable from no branch"])
    }

    func testANewWorktreeGoesWhereTheRepositoryKeepsThem() {
        XCTAssertEqual(
            WorktreePlace.path(for: "feat/drawer", main: "/p/helm", keepsWorktreesInside: true),
            "/p/helm/.worktrees/feat-drawer")
        XCTAssertEqual(
            WorktreePlace.path(for: "feat/drawer", main: "/p/app", keepsWorktreesInside: false),
            "/p/app-feat-drawer")
    }
}
