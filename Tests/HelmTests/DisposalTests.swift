import XCTest

@testable import Helm

/// Disposal: the verb that reclaims disk, and the one report where a reassuring lie is
/// least affordable.
///
/// The engine's own source states the trap: *"an empty `discarded` beside this is 'unknown',
/// not 'nothing' — the one distinction a disposal report must never lose."* Same three-state
/// shape as `GitStatus`, on an irreversible action.
final class DisposalTests: XCTestCase {

    private func report(
        discarded: [String], error: String? = nil, forced: Bool = false
    )
        -> DisposalReport
    {
        DisposalReport(
            id: "k", worktree: "triage-1343", branch: "kild/triage-1343", branchKept: true,
            removed: "/worktrees/triage-1343", discarded: discarded, discardedError: error,
            forced: forced, message: "Removed worktree 'triage-1343'. Branch kept.")
    }

    // MARK: - The three states of "what was discarded"

    func testKnownDiscardsAreReported() {
        XCTAssertEqual(report(discarded: ["a.swift"]).discardedFiles, ["a.swift"])
    }

    /// Measured, and genuinely nothing.
    func testAMeasuredEmptyListIsNothing() {
        XCTAssertEqual(report(discarded: []).discardedFiles, [])
    }

    /// The dangerous one. `discarded: []` with an error set means git could not tell us —
    /// and reporting "nothing was discarded" there would be the most reassuring possible
    /// message about an action that cannot be undone.
    func testAnEmptyListWithAnErrorIsUnknownNotNothing() {
        let r = report(discarded: [], error: "fatal: not a git repository")
        XCTAssertNil(r.discardedFiles, "unknown must not read as nothing")
        XCTAssertNotEqual(r.discardedFiles, [], "and must be distinguishable from measured-empty")
    }

    /// The summary must not append a discard clause it cannot support.
    func testTheSummaryStaysSilentWhenTheDiscardIsUnknown() {
        let r = report(discarded: [], error: "git exploded")
        XCTAssertEqual(
            Disposal.summary(of: r), r.message,
            "the engine's message already carries its own 'could not determine' clause")
    }

    func testTheSummaryNamesKnownDiscards() {
        let summary = Disposal.summary(of: report(discarded: ["a.swift", "b.swift"]))
        XCTAssertTrue(summary.contains("a.swift"))
        XCTAssertTrue(summary.contains("b.swift"))
    }

    /// A tree with hundreds of untracked files must not paste all of them into a dialog.
    func testALongDiscardListIsTruncatedWithACount() {
        let files = (1...12).map { "file\($0).swift" }
        let summary = Disposal.summary(of: report(discarded: files))
        XCTAssertTrue(summary.contains("and 7 more"), summary)
    }

    // MARK: - What may be disposed

    /// Orphans are the whole point: they exist only as trees, which is exactly why they
    /// are the ones holding 5.4 GB.
    func testAWorktreeKildIsDisposable() {
        var orphan = Kild(id: "t", name: "t", cwd: "/repo", worktree: "t", agents: [])
        orphan.orphan = true
        XCTAssertTrue(Disposal.isDisposable(orphan))
    }

    /// A kild that ran in the main checkout has no tree to remove. Offering the action
    /// would produce a refusal the operator could have been spared — and briefly imply
    /// their checkout was about to be deleted.
    func testAKildInTheMainCheckoutIsNotDisposable() {
        let inPlace = Kild(id: "k", name: "k", cwd: "/repo", worktree: nil, agents: [])
        XCTAssertFalse(Disposal.isDisposable(inPlace))
    }

    // MARK: - Saying what will actually happen

    /// The branch survives on every path, `force` included. An operator who believes they
    /// are deleting commits will not press the button — and would be wrong to fear it.
    func testTheConfirmationSaysTheBranchIsKept() {
        let kild = Kild(id: "t", name: "t", cwd: "/repo", worktree: "triage-1343", agents: [])
        let text = Disposal.confirmation(for: kild)
        XCTAssertTrue(text.contains("kild/triage-1343"))
        XCTAssertTrue(text.contains("kept"))
        XCTAssertTrue(text.contains("discarded"), "and it is honest about what IS lost")
    }

    // MARK: - Refusals

    /// The guard doing its job. A refusal naming unlanded commits is the reason this action
    /// is safe to offer at all.
    func testARefusalOverUnlandedWorkIsRecognisable() {
        let refusal = DisposalRefusal(
            error: "refusing: 3 commits not reachable from base", code: "unlanded",
            branch: "kild/x", commits: 3, tip: "land it, or pass force")
        XCTAssertTrue(refusal.isUnlandedWork)
        XCTAssertFalse(refusal.isNothingToDispose)
        XCTAssertEqual(refusal.commits, 3)
    }

    func testARefusalWithNoWorktreeIsNotAFailureOfWork() {
        let refusal = DisposalRefusal(
            error: "ran in the main checkout — it has no worktree to dispose of",
            code: "no_worktree")
        XCTAssertTrue(refusal.isNothingToDispose)
        XCTAssertFalse(refusal.isUnlandedWork, "nothing is at stake; there is just nothing to do")
    }

    /// Captured from the engine's handler shape: refusals carry `error` and `code`, and
    /// `commits`/`tip`/`branch` only sometimes.
    func testARefusalDecodesWithOnlyItsRequiredFields() throws {
        let json = #"{"error":"kild is archived","code":"invalid_state"}"#
        let refusal = try JSONDecoder().decode(DisposalRefusal.self, from: Data(json.utf8))
        XCTAssertEqual(refusal.code, "invalid_state")
        XCTAssertNil(refusal.commits)
        XCTAssertFalse(refusal.isUnlandedWork)
    }

    func testAReportDecodesFromTheEnginesSuccessShape() throws {
        let json = """
            {"ok":true,"id":"k","worktree":"triage-1343","branch":"kild/triage-1343",
             "branchKept":true,"removed":"/worktrees/triage-1343","discarded":[],
             "forced":false,"message":"Removed worktree 'triage-1343'. Branch kept."}
            """
        let report = try JSONDecoder().decode(DisposalReport.self, from: Data(json.utf8))
        XCTAssertTrue(report.branchKept)
        XCTAssertEqual(report.discardedFiles, [], "measured empty, not unknown")
    }
}
