import XCTest

@testable import Helm

/// The bar's right-hand side: three lookups on one key, and the emptiness rules around
/// them. Small, and worth having anyway — every one of these cases is a way to render a
/// separator with nothing on one side of it.
final class StatusSummaryTests: XCTestCase {
    private let workspace = Workspace(path: "/tmp/helm-status")

    func testReportsTheSelectedWorkspacesOwnFacts() {
        let summary = StatusSummary.of(
            workspace: workspace,
            branches: [
                workspace.path: "feat/design-primitives",
                WorkspacePath("/tmp/other"): "main",
            ],
            presence: [workspace.path.value: .notWorking, "/tmp/other": .working]
        )
        XCTAssertEqual(summary.workspace, "helm-status")
        XCTAssertEqual(summary.branch, "feat/design-primitives")
        XCTAssertEqual(summary.agents, .notWorking)
        XCTAssertEqual(summary.agentLabel, "your turn")
    }

    /// Nothing open means nothing to say, however much a dictionary still remembers — the
    /// bar goes empty rather than reporting the last workspace's branch as the current one.
    func testNothingOpenSaysNothing() {
        let summary = StatusSummary.of(
            workspace: nil,
            branches: [WorkspacePath("/tmp/other"): "main"],
            presence: ["/tmp/other": .working]
        )
        XCTAssertEqual(summary, .none)
        XCTAssertNil(summary.agentLabel)
    }

    /// A folder that is not a repository has no entry, and reads as "no branch", not as a gap
    /// between two separators.
    func testAFolderWithNoBranchShowsNoBranch() {
        let summary = StatusSummary.of(workspace: workspace, branches: [:], presence: [:])
        XCTAssertEqual(summary.workspace, "helm-status")
        XCTAssertNil(summary.branch)
    }

    /// No agent is a third answer, not a quiet version of "working" — same split `AgentDot`
    /// makes, said in words.
    func testAgentLabelDistinguishesAbsenceFromWorking() {
        func label(_ presence: AgentPresence?) -> String? {
            StatusSummary.of(
                workspace: workspace,
                branches: [:],
                presence: presence.map { [workspace.path.value: $0] } ?? [:]
            ).agentLabel
        }
        XCTAssertNil(label(nil))
        XCTAssertEqual(label(.working), "working")
        XCTAssertEqual(label(.notWorking), "your turn")
    }
}
