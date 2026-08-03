import XCTest

@testable import Helm

final class ArchonRunTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        JSONDecoder.archon()
    }

    /// Real output from a real install, byte for byte. **This is the whole defence.** The
    /// decoder in this PR was written from an imagined payload and its tests from the same
    /// imagination: 514 green while the feature could not display one run. A literal in a test
    /// file drifts with the decoder because whoever changes the decoder edits it; a captured
    /// file does not, because making it pass means changing what Archon printed.
    ///
    /// Recapture with `archon workflow runs --json` and
    /// `archon workflow get <id> --json --verbose`, both run inside a project.
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    // MARK: - Against what the CLI actually printed

    func testDecodesTheRunsPayloadArchonActuallyPrints() throws {
        let response = try decoder().decode(
            ArchonRunsResponse.self, from: try fixture("workflow-runs"))

        XCTAssertFalse(response.runs.isEmpty)
        XCTAssertNotNil(
            response.runs[0].startedAt,
            "SQLite datetimes, not ISO8601 — assuming otherwise threw on every real row")
        XCTAssertEqual(response.counts["all"], 128)
        XCTAssertEqual(response.counts["completed"], 97)
        XCTAssertTrue(
            response.scopeFallback,
            "captured from a git worktree, which is not the codebase's registered directory — "
                + "so Archon answered globally and said so")
        XCTAssertGreaterThan(
            response.total, response.runs.count,
            "the row list is capped; the counts are over everything")
    }

    func testDecodesTheVerboseRunPayloadArchonActuallyPrints() throws {
        let run = try decoder().decode(ArchonRun.self, from: try fixture("workflow-get-verbose"))

        XCTAssertEqual(run.status, "failed")
        XCTAssertNotNil(run.startedAt)
        XCTAssertNotNil(run.completedAt)
        XCTAssertEqual(run.nodes?.count, 27)
        XCTAssertEqual(run.nodes?.first?.nodeId, "parse-request")
        XCTAssertNotNil(run.nodes?.first?.outputPreview)
        XCTAssertTrue(
            run.metadata?.error?.contains("create-pr") == true,
            "`failed` does not mean the work failed; the reason is the only thing that says so")
    }

    /// The subline reads this, so which node it picks is a decision worth pinning. Nodes
    /// arrive in DAG order and a fan-out leaves completed nodes *after* the interesting one.
    func testTheCurrentNodeIsTheRunningOneAndOtherwiseTheLast() throws {
        let run = try decoder().decode(ArchonRun.self, from: try fixture("workflow-get-verbose"))
        XCTAssertEqual(
            run.currentNode?.nodeId, run.nodes?.last?.nodeId,
            "nothing is running in this capture, so the last node is what is worth showing")

        let live = ArchonRun.fixture(nodes: [
            .fixture(nodeId: "plan", state: .completed),
            .fixture(nodeId: "implement", state: .running, outputPreview: "writing tests"),
            .fixture(nodeId: "validate", state: .completed),
        ])
        XCTAssertEqual(live.currentNode?.nodeId, "implement")
        XCTAssertNil(ArchonRun.fixture(nodes: []).currentNode)
    }

    func testThePreviewIsFlattenedToOneLine() {
        let node = ArchonNode.fixture(outputPreview: "I'll inspect\nthe   manifest\n\nthen build.")
        XCTAssertEqual(node.previewLine, "I'll inspect the manifest then build.")
        XCTAssertNil(ArchonNode.fixture(outputPreview: "   \n ").previewLine)
        XCTAssertNil(ArchonNode.fixture(outputPreview: nil).previewLine)
    }

    // MARK: - Shapes that must survive Archon changing

    func testRetainsUnknownRunStatus() throws {
        let data = Data(
            #"{"runs":[{"id":"r1","workflow_name":"ship","status":"waiting-on-new-archon","started_at":"2026-08-03 10:00:00"}],"total":1,"counts":{"all":1},"scopeFallback":false}"#
                .utf8)
        let response = try decoder().decode(ArchonRunsResponse.self, from: data)

        XCTAssertEqual(response.runs[0].status, "waiting-on-new-archon")
        XCTAssertNil(response.runs[0].workingPath)
    }

    /// REPLACES `testUnknownNodeStateFailsInsteadOfGuessing`, whose subject is gone: node
    /// state was a closed enum and an unrecognised value threw. The throw was not contained
    /// to its node — it failed the whole `nodes` array, so the whole run decode, so a single
    /// new state name from Archon blanked a healthy run's pane. `status` right beside it was
    /// already open for exactly this reason. The property worth holding is the opposite one.
    func testUnknownNodeStateSurvivesInsteadOfFailingTheRun() throws {
        let data = Data(
            #"{"id":"r1","workflow_name":"ship","status":"running","nodes":[{"nodeId":"x","state":"future"},{"nodeId":"y","state":"completed"}]}"#
                .utf8)

        let run = try decoder().decode(ArchonRun.self, from: data)

        XCTAssertEqual(run.nodes?.count, 2, "one unknown state must not take the run with it")
        XCTAssertEqual(run.nodes?[0].state, .unknown("future"))
        XCTAssertEqual(
            run.nodes?[0].state.raw, "future", "the name Archon used reaches the operator")
        XCTAssertEqual(run.nodes?[1].state, .completed, "known states still decode")
    }

    /// ISO8601 is not emitted by anything observed, but Archon is a separate repo that may
    /// start. The fallback costs one branch; losing it silently would cost the feature.
    func testStillAcceptsISO8601IfArchonEverSendsIt() throws {
        let data = Data(
            #"{"id":"r1","workflow_name":"ship","status":"running","started_at":"2026-08-03T10:00:00.123Z"}"#
                .utf8)

        XCTAssertNotNil(try decoder().decode(ArchonRun.self, from: data).startedAt)
    }

    /// A status Archon adds later gets a line without a helm change, and a defined place in
    /// the order rather than wherever the dictionary put it.
    func testCollapsedStatusesAreOrderedAndDropTheTotal() {
        let response = ArchonRunsResponse(
            runs: [], total: 12,
            counts: [
                "all": 12, "completed": 4, "running": 1, "queued": 2, "failed": 3, "paused": 0,
            ],
            scopeFallback: false)

        XCTAssertEqual(
            response.statusCounts,
            [
                ArchonStatusCount(status: "running", count: 1),
                ArchonStatusCount(status: "failed", count: 3),
                ArchonStatusCount(status: "completed", count: 4),
                ArchonStatusCount(status: "queued", count: 2),
            ],
            "`all` is a total, a zero is not worth a line, and an unknown status sorts last")
    }

    // MARK: - What a pane persists

    func testBothPaneAddressesRoundTrip() throws {
        for reference in [
            ArchonPaneRef.run(id: "r1", workflowName: "ship"), .runs(status: "failed"),
        ] {
            XCTAssertEqual(
                try decoder().decode(ArchonPaneRef.self, from: JSONEncoder().encode(reference)),
                reference)
        }
    }

    /// A bench stored by the build before this one holds the bare shape. Rejecting it would
    /// not cost that pane — `WorkspaceContextStore.load` decodes one dictionary for the whole
    /// app, so a single unreadable pane returns `[:]` and takes **every** workspace's
    /// arrangement with it.
    func testTheAddressFromTheBuildBeforeThisOneStillDecodes() throws {
        let stored = Data(#"{"id":"r1","workflowName":"ship"}"#.utf8)

        XCTAssertEqual(
            try decoder().decode(ArchonPaneRef.self, from: stored),
            .run(id: "r1", workflowName: "ship"))
    }

    func testThePaneAddressIsStoredWithNamedKeysRatherThanPositions() throws {
        let json = String(
            decoding: try JSONEncoder().encode(ArchonPaneRef.runs(status: "failed")), as: UTF8.self)
        XCTAssertTrue(json.contains("\"kind\":\"runs\""), json)
        XCTAssertFalse(
            json.contains("_0"),
            "the synthesized shape uses positional keys, which break on any reordering of the "
                + "cases and are unreadable in the stored blob")
    }

    // MARK: - What Enter launches

    /// The pair this replaced could describe states that do not exist —
    /// `(noWorktree: true, branch: "x")` dropped the branch silently.
    func testEveryIsolationChoiceHasExactlyOneArgumentList() {
        XCTAssertEqual(WorktreeChoice.automatic.arguments, [])
        XCTAssertEqual(WorktreeChoice.none.arguments, ["--no-worktree"])
        XCTAssertEqual(WorktreeChoice.branch("x").arguments, ["--branch", "x"])
    }

    /// Adding a flag to the gear must not reset the operator's workflow choice, which is what
    /// synthesized decoding of a new property would do to every config stored before it.
    func testAConfigStoredBeforeAPropertyExistedStillLoads() throws {
        let stored = Data(#"{"workflow":"archon-fix-github-issue"}"#.utf8)

        let config = try JSONDecoder().decode(ArchonLaunchConfig.self, from: stored)

        XCTAssertEqual(config.workflow, "archon-fix-github-issue")
        XCTAssertEqual(config.worktree, .automatic)
    }
}
