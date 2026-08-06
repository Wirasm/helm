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
            contexts: [
                workspace.path.value: WorkspaceContext(branch: "feat/design-primitives"),
                "/tmp/other": WorkspaceContext(branch: "main"),
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
            contexts: ["/tmp/other": WorkspaceContext(branch: "main")],
            presence: ["/tmp/other": .working]
        )
        XCTAssertEqual(summary, .none)
        XCTAssertNil(summary.agentLabel)
    }

    /// A folder that is not a repository, and a context persisted before that was stored as
    /// nil. Both have to read as "no branch", not as a gap between two separators.
    func testAFolderWithNoBranchShowsNoBranch() {
        for branch in [nil, ""] {
            let summary = StatusSummary.of(
                workspace: workspace,
                contexts: [workspace.path.value: WorkspaceContext(branch: branch)],
                presence: [:]
            )
            XCTAssertEqual(summary.workspace, "helm-status")
            XCTAssertNil(summary.branch, "branch was \(String(describing: branch))")
        }
    }

    /// No agent is a third answer, not a quiet version of "working" — same split `AgentDot`
    /// makes, said in words.
    func testAgentLabelDistinguishesAbsenceFromWorking() {
        func label(_ presence: AgentPresence?) -> String? {
            StatusSummary.of(
                workspace: workspace,
                contexts: [:],
                presence: presence.map { [workspace.path.value: $0] } ?? [:]
            ).agentLabel
        }
        XCTAssertNil(label(nil))
        XCTAssertEqual(label(.working), "working")
        XCTAssertEqual(label(.notWorking), "your turn")
    }
}
