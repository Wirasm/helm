import XCTest

@testable import Helm

/// The gate value, and the three facts it exists to establish: is this waiting for me, does the
/// answer need words, and what does the command line look like.
///
/// **The JSON here is Archon's own shape, not an imagined one.** Every key is copied from
/// `ApprovalContext` in `packages/workflows/src/schemas/workflow-run.ts` and from what
/// `pauseWorkflowRun` writes in `packages/core/src/db/workflows.ts` — including the explicit
/// `"resolved": null` on a fresh pause, which is not an omission Archon could have made (SQLite
/// deep-merges the new approval into the stored one, so an absent key would inherit a stale
/// `"approved"` from the previous gate).
final class ArchonGateTests: XCTestCase {

    // MARK: - Reading one

    private func decode(_ json: String) throws -> ArchonRun {
        try JSONDecoder.archon().decode(ArchonRun.self, from: Data(json.utf8))
    }

    func testAFreshGateIsReadOffTheRunsPayload() throws {
        let run = try decode(
            """
            {"id":"r1","workflow_name":"ship","status":"paused","working_path":"/tmp/w",
             "metadata":{"approval":{"nodeId":"review","message":"Ship the migration?",
             "type":"approval","captureResponse":false,"resolved":null}}}
            """)

        let gate = try XCTUnwrap(run.gate)
        XCTAssertEqual(gate.nodeId, "review")
        XCTAssertEqual(gate.message, "Ship the migration?")
        XCTAssertEqual(gate.type, .approval)
        XCTAssertTrue(gate.isAwaitingDecision)
        XCTAssertNil(gate.blockedReason)
    }

    /// Archon declares `type` optional and a plain DAG approval node writes none, so a missing
    /// key is a gate rather than an unknown one.
    func testAMissingTypeIsAPlainApprovalGate() throws {
        let run = try decode(
            """
            {"id":"r1","workflow_name":"ship","status":"paused",
             "metadata":{"approval":{"nodeId":"review","message":"ok?"}}}
            """)

        XCTAssertEqual(run.gate?.type, .approval)
        XCTAssertEqual(run.isAwaitingDecision, true)
    }

    /// The lesson `ArchonNode.State` already paid for, applied one level up: Archon's vocabulary
    /// grows in a repo with zero knowledge of helm, and a word helm has not heard of must cost
    /// the gate's *verbs*, never the run's decode.
    func testAnUnknownGateKindStillDecodes() throws {
        let run = try decode(
            """
            {"id":"r1","workflow_name":"ship","status":"paused",
             "metadata":{"approval":{"nodeId":"n","message":"m","type":"quorum"}}}
            """)

        XCTAssertEqual(run.gate?.type, .unknown("quorum"))
        XCTAssertTrue(run.isAwaitingDecision, "an unrecognised kind is still a gate to answer")
    }

    /// The other malformed shape, and the one `ArchonGate`'s own leniency cannot catch:
    /// `approval` present but not an object. A stale run really can carry this, and it used to
    /// be the kind of thing that threw through the whole `runs` decode and blanked the rail.
    func testAnUnreadableApprovalCostsTheGateAndNotTheRun() throws {
        let run = try decode(
            """
            {"id":"r1","workflow_name":"ship","status":"paused",
             "metadata":{"error":"boom","approval":"pending"}}
            """)

        XCTAssertEqual(run.id, "r1", "the run survives")
        XCTAssertEqual(run.metadata?.error, "boom", "and so does its sibling key")
        XCTAssertNil(run.gate)
        XCTAssertFalse(run.isAwaitingDecision)
    }

    /// **Archon never clears the approval context on resume** — the executor reads it at
    /// resume time — so a finished run still carries the last gate it passed. Reading it on any
    /// status but `paused` would put a stale question under a completed row.
    func testAGateIsOnlyReadWhilePaused() throws {
        let run = try decode(
            """
            {"id":"r1","workflow_name":"ship","status":"completed",
             "metadata":{"approval":{"nodeId":"review","message":"Ship it?","resolved":"approved"}}}
            """)

        XCTAssertNil(run.gate)
        XCTAssertFalse(run.isPaused)
    }

    // MARK: - Whether it is yours to answer

    /// `approve` on a resolved gate throws *"was already approved and is awaiting resume"*. The
    /// run stays `paused` through that window, so status alone cannot tell them apart.
    func testAResolvedGateIsNotWaitingForYou() {
        for (resolved, expected) in [
            ("approved", "Approved — waiting for Archon to resume it."),
            ("rejected", "Rejected — waiting for Archon to resume it."),
        ] {
            let gate = ArchonGate.fixture(resolved: resolved)
            XCTAssertFalse(gate.isAwaitingDecision)
            XCTAssertEqual(gate.blockedReason, expected)
        }
    }

    /// Approving a `child_workflow` pause throws and tells you to approve the child by id. The
    /// row carries that id rather than a disabled button.
    func testAChildWorkflowPauseSendsYouToTheChild() {
        let gate = ArchonGate.fixture(type: .childWorkflow, childRunId: "abcdef1234567890")

        XCTAssertFalse(gate.isAwaitingDecision)
        XCTAssertEqual(gate.blockedReason, "Blocked on sub-run abcdef12 — decide that one.")
    }

    // MARK: - Whether the answer needs words

    /// **Reject always collects a reason**: it is fed to the `on_reject` rework prompt, and a
    /// rework told only that it failed is the same defect as approving blind.
    func testRejectAlwaysCollectsAReason() {
        for gate in [
            ArchonGate.fixture(),
            ArchonGate.fixture(type: .interactiveLoop),
            ArchonGate.fixture(captureResponse: true),
        ] {
            XCTAssertTrue(gate.needsText(for: .reject))
        }
    }

    /// A plain gate's comment reaches an audit event nobody reads, so demanding a sentence for
    /// it would be a second click that buys nothing.
    func testAPlainApprovalSendsWithoutAsking() {
        XCTAssertFalse(ArchonGate.fixture().needsText(for: .approve))
        XCTAssertFalse(ArchonGate.fixture(type: .writeback).needsText(for: .approve))
    }

    /// `captureResponse` stores the comment as `$nodeId.output`, so a blind approve writes the
    /// literal string `Approved` into the run for the next node to consume.
    func testACaptureResponseGateCollectsTheOutput() {
        XCTAssertTrue(ArchonGate.fixture(captureResponse: true).needsText(for: .approve))
    }

    /// Archon #2074: an interactive loop discriminates finalize-from-iterate on whether a
    /// comment was given *at all* (`loop_feedback_given`). Both are real answers, so the
    /// operator has to be the one choosing.
    func testAnInteractiveLoopGateCollectsItsFeedback() {
        XCTAssertTrue(ArchonGate.fixture(type: .interactiveLoop).needsText(for: .approve))
    }

    // MARK: - The command

    /// **The flag form, not the positional one.** Archon takes either, but a positional loses a
    /// reason beginning with a dash and rejoins a multi-word one on spaces.
    func testTheDecisionBecomesAFlaggedCommand() {
        XCTAssertEqual(
            ArchonGateDecision.approve.arguments(for: "r1", text: "ship it"),
            ["workflow", "approve", "r1", "--json", "--comment", "ship it"])
        XCTAssertEqual(
            ArchonGateDecision.reject.arguments(for: "r1", text: "--tests are red"),
            ["workflow", "reject", "r1", "--json", "--reason", "--tests are red"])
    }

    /// Empty and whitespace-only both mean *no comment*, and the difference is load-bearing:
    /// Archon converts an empty comment to `undefined` explicitly so a signal-bearing loop gate
    /// finalizes instead of running another iteration. Passing `--comment "   "` would record
    /// whitespace as feedback and iterate.
    func testAnEmptyAnswerCarriesNoFlagAtAll() {
        for text in [nil, "", "   \n "] {
            XCTAssertEqual(
                ArchonGateDecision.approve.arguments(for: "r1", text: text),
                ["workflow", "approve", "r1", "--json"])
        }
    }

    // MARK: - What comes back

    /// `--json` verbs catch their own failures, print `{"ok": false, …}` and exit **zero**, so
    /// `ok` is the contract and the exit status is not.
    func testARefusalIsAZeroExitWithOkFalse() throws {
        let payload = """
            {"ok":false,"runId":"r1","action":"approve","error":"Cannot approve run with status 'running'."}
            """
        let acknowledgement = try JSONDecoder.archon().decode(
            ArchonActionAcknowledgement.self, from: Data(payload.utf8))

        XCTAssertFalse(acknowledgement.ok)
        XCTAssertFalse(acknowledgement.leavesRunResumable)
        XCTAssertEqual(acknowledgement.error, "Cannot approve run with status 'running'.")
    }

    /// `resumable: true` is the whole reason `ArchonClient.resume(_:)` exists — the decision is
    /// recorded and the run is left parked for the caller to drive.
    func testARecordedDecisionReportsThatItDidNotRestartTheRun() throws {
        let payload = """
            {"ok":true,"runId":"r1","action":"approve","workflowName":"ship","resumable":true}
            """
        let acknowledgement = try JSONDecoder.archon().decode(
            ArchonActionAcknowledgement.self, from: Data(payload.utf8))

        XCTAssertTrue(acknowledgement.leavesRunResumable)
    }

    /// A rejection that cancelled the run has nothing to resume — `resumable: !cancelled` in
    /// Archon's own emitter.
    func testACancellingRejectionLeavesNothingToResume() throws {
        let payload = """
            {"ok":true,"runId":"r1","action":"reject","cancelled":true,
             "maxAttemptsReached":true,"resumable":false}
            """
        let acknowledgement = try JSONDecoder.archon().decode(
            ArchonActionAcknowledgement.self, from: Data(payload.utf8))

        XCTAssertTrue(acknowledgement.ok)
        XCTAssertFalse(acknowledgement.leavesRunResumable)
    }
}
