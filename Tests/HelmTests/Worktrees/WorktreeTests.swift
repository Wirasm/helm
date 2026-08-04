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

    func testRecognisesOnlyDocumentedArchonBranchFamilies() {
        for branch in [
            "archon/task-123", "archon/issue-141", "archon/pr-9", "archon/review-9",
            "archon/thread-abc",
        ] {
            XCTAssertEqual(WorktreeKind.classify(branch: branch), .archon, branch)
        }
        XCTAssertEqual(WorktreeKind.classify(branch: "feature/archon-task"), .git)
        XCTAssertEqual(WorktreeKind.classify(branch: nil), .unknown)
    }

    func testCleanupRequiresAMergedExistingOrdinaryLinkedWorktree() {
        XCTAssertEqual(
            Worktree.fixture().cleanupRoute, .git(path: "/tmp/project-linked"))
        XCTAssertEqual(
            Worktree.fixture(branch: "archon/task-1").cleanupRoute,
            .archon(branch: "archon/task-1"))

        XCTAssertNil(Worktree.fixture(mergedState: .unmerged).cleanupRoute)
        XCTAssertNil(Worktree.fixture(mergedState: .unknown).cleanupRoute)
        XCTAssertNil(Worktree.fixture(isMain: true).cleanupRoute)
        XCTAssertNil(Worktree.fixture(exists: false).cleanupRoute)
        XCTAssertNil(Worktree.fixture(branch: nil).cleanupRoute)
        XCTAssertNil(Worktree.fixture(detached: true).cleanupRoute)
        XCTAssertNil(Worktree.fixture(locked: true).cleanupRoute)
        XCTAssertNil(Worktree.fixture(prunable: true).cleanupRoute)
        XCTAssertNil(Worktree.fixture(bare: true).cleanupRoute)
    }
}
