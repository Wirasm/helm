import XCTest

@testable import Helm

/// The bar's right-hand side: two lookups on one key, and the emptiness rule around them. Every
/// one of these cases is a way to render a separator with nothing on one side of it.
final class StatusSummaryTests: XCTestCase {
    private let workspace = Workspace(path: "/tmp/helm-status")

    func testReportsTheSelectedWorkspacesOwnFacts() {
        let summary = StatusSummary.of(
            workspace: workspace,
            branches: [
                workspace.path: "feat/design-primitives",
                WorkspacePath("/tmp/other"): "main",
            ]
        )
        XCTAssertEqual(summary.workspace, "helm-status")
        XCTAssertEqual(summary.branch, "feat/design-primitives")
    }

    /// Nothing open means nothing to say, however much a dictionary still remembers — the
    /// bar goes empty rather than reporting the last workspace's branch as the current one.
    func testNothingOpenSaysNothing() {
        let summary = StatusSummary.of(
            workspace: nil, branches: [WorkspacePath("/tmp/other"): "main"])
        XCTAssertEqual(summary, .none)
    }

    /// A folder that is not a repository has no entry, and reads as "no branch", not as a gap
    /// between two separators.
    func testAFolderWithNoBranchShowsNoBranch() {
        let summary = StatusSummary.of(workspace: workspace, branches: [:])
        XCTAssertEqual(summary.workspace, "helm-status")
        XCTAssertNil(summary.branch)
    }
}
