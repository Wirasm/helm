import XCTest

@testable import Helm

final class ArchonRunLinkTests: XCTestCase {
    /// **The test this type exists for.** Archon's worktree path is `join(base, branchName)` and
    /// its branch names contain a slash, so the directory nests. Reading the last component
    /// alone yields `task-…`, which is not a branch, and every lookup would find nothing —
    /// silently, since a missing pull request is indistinguishable from a wrong branch name.
    func testTheBranchKeepsItsArchonPrefixRatherThanBeingTheBasename() {
        let link = ArchonRunLink.parse(
            workingPath:
                "/Users/x/.archon/workspaces/Wirasm/helm/worktrees/archon/task-fix-issue-1785773886177"
        )

        XCTAssertEqual(link?.branch, "archon/task-fix-issue-1785773886177")
        XCTAssertEqual(link?.owner, "Wirasm")
        XCTAssertEqual(link?.repo, "helm")
        XCTAssertEqual(link?.repository, "Wirasm/helm")
    }

    /// A same-repo pull-request run works on the PR's own branch, which carries no `archon/`.
    /// This is why the rule is "everything after `worktrees`" and not "strip a known prefix".
    func testABranchWithNoArchonPrefixStillParses() {
        let link = ArchonRunLink.parse(
            workingPath: "/Users/x/.archon/workspaces/coleam00/Archon/worktrees/feat/some-thing")

        XCTAssertEqual(link?.branch, "feat/some-thing")
        XCTAssertEqual(link?.repository, "coleam00/Archon")
    }

    func testASingleSegmentBranchParses() {
        let link = ArchonRunLink.parse(
            workingPath: "/Users/x/.archon/workspaces/Wirasm/helm/worktrees/hotfix")

        XCTAssertEqual(link?.branch, "hotfix")
    }

    /// `--no-worktree` leaves `working_path` as the plain checkout. There is no branch to
    /// derive and no repo to name, so the row must not become a button.
    func testAPlainCheckoutYieldsNoLink() {
        XCTAssertNil(ArchonRunLink.parse(workingPath: "/Users/x/Projects/mine/sild/helm"))
    }

    func testAMissingPathYieldsNoLink() {
        XCTAssertNil(ArchonRunLink.parse(workingPath: nil))
        XCTAssertNil(ArchonRunLink.parse(workingPath: ""))
    }

    /// A worktrees directory with nothing after it names no branch.
    func testATrailingWorktreesSegmentYieldsNoLink() {
        XCTAssertNil(
            ArchonRunLink.parse(workingPath: "/Users/x/.archon/workspaces/Wirasm/helm/worktrees"))
    }

    /// A repo-local worktree base has no `workspaces/<owner>/<repo>` to read, so there is no
    /// repository to ask GitHub about. Nil rather than a guessed owner.
    func testARepoLocalWorktreeBaseYieldsNoLink() {
        XCTAssertNil(
            ArchonRunLink.parse(workingPath: "/Users/x/Projects/helm/worktrees/archon/task-1"))
    }

    func testTheBranchURLIsTheRepositoryTree() {
        let link = ArchonRunLink.parse(
            workingPath: "/Users/x/.archon/workspaces/Wirasm/helm/worktrees/archon/task-1")

        XCTAssertEqual(
            link?.branchURL?.absoluteString, "https://github.com/Wirasm/helm/tree/archon/task-1")
    }

    /// Homebrew ahead of the inherited PATH — a bundled app inherits launchd's, which has never
    /// heard of `gh`.
    func testHomebrewLeadsThePathSoGhIsFound() {
        let environment = ArchonRunOpener.environment(inherited: ["PATH": "/usr/bin:/bin"])

        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }

    func testAnEmptyInheritedPathIsNotLeftAsATrailingColon() {
        XCTAssertEqual(
            ArchonRunOpener.environment(inherited: ["PATH": ""])["PATH"],
            "/opt/homebrew/bin:/usr/local/bin")
        XCTAssertEqual(
            ArchonRunOpener.environment(inherited: [:])["PATH"],
            "/opt/homebrew/bin:/usr/local/bin")
    }
}
