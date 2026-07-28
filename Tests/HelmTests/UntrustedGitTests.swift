import XCTest

@testable import Helm

/// What helm does when git could not be read.
///
/// This is the sharpest edge in the whole wire contract, and it is sharp precisely because
/// the engine is careful: a failed probe never throws, it returns a *well-formed* object
/// with safe defaults — `ahead: 0`, `dirty: false`, `changedFiles: []`, `conflictsWithBase:
/// nil` — and puts the reason in `error`.
///
/// Every one of those defaults reads as good news. A client that does not check `error`
/// will render "clean · nothing to land · no collisions" over a measurement that never
/// happened, and will do so most confidently on the screen where being wrong costs most.
/// These tests exist so that cannot regress silently.
final class UntrustedGitTests: XCTestCase {

    private func kild(_ name: String, git: GitStatus?, agents: [Agent] = []) -> Kild {
        Kild(id: name, name: name, cwd: "/repo", base: "development", agents: agents, git: git)
    }

    // MARK: - The type says so

    func testAFailedProbeIsNotTrustworthy() {
        XCTAssertFalse(GitFixture.failed().isTrustworthy)
        XCTAssertTrue(GitFixture.measured().isTrustworthy)
    }

    /// The defaults that make this dangerous, asserted directly so the hazard is documented
    /// in the test suite rather than only in prose.
    func testAFailedProbeLooksExactlyLikeACleanTree() {
        let failed = GitFixture.failed()
        XCTAssertEqual(failed.ahead, 0)
        XCTAssertFalse(failed.dirty)
        XCTAssertEqual(failed.changedFiles, [])
        XCTAssertNotNil(failed.error, "only this distinguishes it")
    }

    /// `nil` is undetermined, not clean. Three states, and only one of them is a promise.
    func testMergesCleanlyIsNilWhenUndeterminedAndWhenUntrusted() {
        XCTAssertEqual(GitFixture.measured(conflictsWithBase: false).mergesCleanly, true)
        XCTAssertEqual(GitFixture.measured(conflictsWithBase: true).mergesCleanly, false)
        XCTAssertNil(
            GitFixture.measured(conflictsWithBase: nil).mergesCleanly,
            "the engine declined to say; helm must not answer for it")
        XCTAssertNil(GitFixture.failed().mergesCleanly)
    }

    // MARK: - Collisions

    /// An empty `changedFiles` from a failed probe means "unknown", not "touches nothing".
    /// Deriving from it reports the most reassuring possible answer from no evidence.
    func testAKildWhoseGitFailedIsExcludedFromCollisionDerivation() {
        let kilds = [
            kild("a", git: GitFixture.measured(changedFiles: ["Shared.swift"])),
            kild("b", git: GitFixture.failed()),
        ]
        XCTAssertTrue(
            Attention.collisions(among: kilds).isEmpty,
            "b's files are unknown, so no claim can be made about b")
    }

    func testTrustworthyKildsStillCollideAroundAFailedOne() {
        let kilds = [
            kild("a", git: GitFixture.measured(changedFiles: ["Shared.swift"])),
            kild("b", git: GitFixture.failed()),
            kild("c", git: GitFixture.measured(changedFiles: ["Shared.swift"])),
        ]
        let collisions = Attention.collisions(among: kilds)
        XCTAssertEqual(collisions["a"]?.first?.other, "c")
        XCTAssertNil(collisions["b"])
    }

    // MARK: - The land gate

    private func gate(_ kild: Kild, report: LandReport, collisions: [Collision] = [])
        -> LandGate
    {
        LandGate.make(
            kild: kild, report: report, collisions: collisions, runningAgents: kild.agents)
    }

    private func landable() -> LandReport {
        LandReport(ok: true, ahead: 3, behind: 0, dirty: false, conflictsWithBase: false)
    }

    /// The headline case. Without this the gate shows its greenest face over a repository
    /// it could not read.
    func testAFailedMeasurementBlocksLanding() {
        let g = gate(kild("a", git: GitFixture.failed()), report: landable())
        XCTAssertFalse(g.canLand)
        XCTAssertTrue(g.checks.contains { $0.id == "measurement" && $0.blocks })
    }

    /// The reason is shown, not swallowed — "could not read git state" is actionable in a
    /// way that a disabled button with no explanation is not.
    func testTheMeasurementFailureIsNamed() {
        let g = gate(
            kild("a", git: GitFixture.failed("fatal: not a git repository")),
            report: landable())
        XCTAssertTrue(
            g.checks.contains { $0.text.contains("fatal: not a git repository") })
    }

    func testATrustworthyMeasurementAddsNoSuchCheck() {
        let g = gate(kild("a", git: GitFixture.measured()), report: landable())
        XCTAssertFalse(g.checks.contains { $0.id == "measurement" })
        XCTAssertTrue(g.canLand)
    }

    /// A kild with no git block at all (the cheap listing, or an orphan) is *unmeasured*,
    /// not *failed*. It gets no measurement check — the absence is honest and there is no
    /// error to report.
    func testAKildWithNoGitBlockIsNotTreatedAsAFailure() {
        let g = gate(kild("a", git: nil), report: landable())
        XCTAssertFalse(g.checks.contains { $0.id == "measurement" })
    }

    // MARK: - Undetermined merges

    /// Reading `nil` as "merges without conflict" would state a guarantee the engine
    /// explicitly declined to make, on the one screen where an unearned reassurance is
    /// most expensive.
    func testAnUndeterminedMergeDoesNotClaimToBeClean() {
        var report = landable()
        report.conflictsWithBase = nil
        let merge = gate(kild("a", git: GitFixture.measured()), report: report)
            .checks.first { $0.id == "merge" }
        XCTAssertEqual(merge?.verdict, .info)
        XCTAssertEqual(merge?.text, "merge cleanliness undetermined")
    }

    /// It is not a conflict either. Refusing on undetermined would strand kilds the engine
    /// simply could not check, which is the same over-strictness that made 116 worktrees
    /// unreclaimable.
    func testAnUndeterminedMergeDoesNotBlock() {
        var report = landable()
        report.conflictsWithBase = nil
        XCTAssertTrue(gate(kild("a", git: GitFixture.measured()), report: report).canLand)
    }

    func testADeterminedConflictStillBlocks() {
        var report = landable()
        report.conflictsWithBase = true
        XCTAssertFalse(gate(kild("a", git: GitFixture.measured()), report: report).canLand)
    }
}
