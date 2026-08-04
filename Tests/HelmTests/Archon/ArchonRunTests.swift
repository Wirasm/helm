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

    /// **Gates, against four real rows rather than four imagined ones.** Captured with
    /// `archon workflow runs --json --all` and filtered to one row per gate shape that exists in
    /// the wild: a live `writeback` gate awaiting a person, an `interactive_loop` gate already
    /// resolved but still `paused`, and two whose runs have since terminated.
    ///
    /// **Two of these would have been got wrong from the schema alone.** `ApprovalContext`
    /// documents `resolved` as an explicit null written on every fresh pause — the live row here
    /// omits the key entirely, because the engine-level writeback gate does not go through
    /// `pauseWorkflowRun`. And the real metadata carries `isolation`, `isolation_env_id` and
    /// `pending_writeback` alongside `approval`, so a strict decode of that object would have
    /// thrown on the commonest gate there is.
    func testDecodesTheGateMetadataArchonActuallyPrints() throws {
        let response = try decoder().decode(
            ArchonRunsResponse.self, from: try fixture("workflow-runs-gated"))
        let byID = Dictionary(uniqueKeysWithValues: response.runs.map { ($0.shortID, $0) })

        let live = try XCTUnwrap(byID["082676c1"])
        XCTAssertTrue(live.isPaused)
        XCTAssertEqual(live.gate?.type, .writeback)
        XCTAssertNil(live.gate?.resolved, "the key is absent on this path, not null")
        XCTAssertTrue(live.isAwaitingDecision)
        XCTAssertTrue(
            live.gate?.message.contains("Approve to APPLY") == true,
            "the subline is Archon's own question, and it is markdown with newlines in it")

        let parked = try XCTUnwrap(byID["8b6229fa"])
        XCTAssertTrue(parked.isPaused, "still paused — status alone cannot tell these apart")
        XCTAssertEqual(parked.gate?.type, .interactiveLoop)
        XCTAssertFalse(
            parked.isAwaitingDecision,
            "already approved and awaiting resume; approving again throws")
        XCTAssertEqual(parked.gate?.blockedReason, "Approved — waiting for Archon to resume it.")

        for terminal in ["2f4c6b12", "e40b6bb9"] {
            XCTAssertNil(
                byID[terminal]?.gate,
                "Archon never clears the approval context, so a finished run still carries the "
                    + "last gate it passed — reading it would put a stale question on the row")
        }
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

    /// **The tint mapping is Archon's status vocabulary, not its brand.** The console keeps
    /// the two apart on purpose so a brand swap cannot change what a colour means, and the
    /// easy mistake here is painting every Archon surface magenta.
    func testStatusTintsFollowArchonsStatusVocabularyRatherThanItsBrand() {
        XCTAssertEqual(ArchonRunsResponse.tint(for: "running"), .running)
        XCTAssertEqual(ArchonRunsResponse.tint(for: "completed"), .success)
        XCTAssertEqual(ArchonRunsResponse.tint(for: "failed"), .error)
        XCTAssertEqual(ArchonRunsResponse.tint(for: "paused"), .warning)
        XCTAssertEqual(
            ArchonRunsResponse.tint(for: "waiting-on-new-archon"), .neutral,
            "a status Archon adds later still gets a line, in the colour that claims nothing")
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

    /// **Deleted rather than rewritten, and this is the one case AGENTS.md allows.** It
    /// asserted the ordering of the collapsed count lines — `all` dropped, zeroes dropped, an
    /// unknown status sorted last. There are no collapsed count lines any more, so
    /// `statusCounts`, `ArchonStatusCount` and `statusOrder` went with them; keeping the test
    /// would have meant keeping production code nothing reads, alive only to be tested.
    ///
    /// `counts` itself is still decoded — it is part of Archon's payload and cheap to carry —
    /// and `testTheRunsResponseDecodesTheCapturedFixture` still covers that.
    func testTheCountsDictionaryIsStillDecoded() throws {
        let response = ArchonRunsResponse(
            runs: [], total: 12,
            counts: ["all": 12, "completed": 4, "running": 1],
            scopeFallback: false)

        XCTAssertEqual(response.counts["completed"], 4)
        XCTAssertEqual(response.total, 12)
    }

    // MARK: - The id the rail shows is not the id the rail copies

    /// **What is drawn is a truncation of what is copied, and this measures the gap.**
    ///
    /// The rail's rows put `shortID` on screen and `CopyableLabel(value: run.id)` on the
    /// clipboard (#169). The reason that asymmetry is worth a type and a test is entirely
    /// visible here: against what Archon actually printed, every id is four times the length
    /// of the label standing in for it, so "copy the label" — the obvious implementation — is
    /// a string that looks right, pastes cleanly, and is three quarters missing.
    func testWhatARowDrawsIsAStrictPrefixOfWhatItCopies() throws {
        let response = try decoder().decode(
            ArchonRunsResponse.self, from: try fixture("workflow-runs"))

        XCTAssertFalse(response.runs.isEmpty)
        for run in response.runs {
            XCTAssertTrue(
                run.id.hasPrefix(run.shortID),
                "the label must be the head of the id, or the two name different runs")
            XCTAssertGreaterThan(
                run.id.count, run.shortID.count,
                "\(run.id) is not longer than the \(run.shortID) drawn for it — if Archon has "
                    + "started printing eight-character ids, #169's whole argument is moot")
            XCTAssertEqual(run.shortID.count, 8)
        }
    }

    /// One definition of the shortening, so the armed-reply line — which holds a run id
    /// without the run — cannot draw a different label from the rows above it.
    func testTheReplyLineShortensARawIdTheSameWayARunDoes() throws {
        let response = try decoder().decode(
            ArchonRunsResponse.self, from: try fixture("workflow-runs"))
        let run = try XCTUnwrap(response.runs.first)

        XCTAssertEqual(ArchonRun.shortID(of: run.id), run.shortID)
    }

    // MARK: - What Enter launches

    /// The pair this replaced could describe states that do not exist —
    /// `(noWorktree: true, branch: "x")` dropped the branch silently.
    func testEveryIsolationChoiceHasExactlyOneArgumentList() {
        XCTAssertEqual(WorktreeChoice.automatic.arguments, [])
        XCTAssertEqual(WorktreeChoice.none.arguments, ["--no-worktree"])
        XCTAssertEqual(WorktreeChoice.branch("x").arguments, ["--branch", "x"])
    }

    /// Adding a flag to the settings must not reset the operator's workflow choice, which is what
    /// synthesized decoding of a new property would do to every config stored before it.
    func testAConfigStoredBeforeAPropertyExistedStillLoads() throws {
        let stored = Data(#"{"workflow":"archon-fix-github-issue"}"#.utf8)

        let config = try JSONDecoder().decode(ArchonLaunchConfig.self, from: stored)

        XCTAssertEqual(config.workflow, "archon-fix-github-issue")
        XCTAssertEqual(config.worktree, .automatic)
    }
}
