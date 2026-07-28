import XCTest

@testable import Helm

/// The land gate's rule, tested without a window.
///
/// Landing is the one action in the model that rewrites a branch other kilds measure
/// against, so "when is this allowed" needs to be checkable directly rather than inferred
/// from whether a button looks grey.
final class LandGateTests: XCTestCase {

    private func kild(_ name: String = "sidebar", agents: [Agent] = [], git: GitStatus? = nil)
        -> Kild
    {
        Kild(
            id: name, name: name, cwd: "/repo", base: "development", agents: agents, git: git)
    }

    private func agent(_ handle: String, idle: Bool? = nil, stopped: Bool? = nil) -> Agent {
        Agent(handle: handle, ownership: .owned, idle: idle, stopped: stopped)
    }

    private func gate(
        _ report: LandReport, collisions: [Collision] = [], agents: [Agent] = [],
        git: GitStatus? = nil
    ) -> LandGate {
        LandGate.make(
            kild: kild(agents: agents, git: git), report: report, collisions: collisions,
            runningAgents: agents)
    }

    // MARK: - Allowing

    func testALandableBranchCanLand() {
        XCTAssertTrue(gate(LandFixture.landable()).canLand)
    }

    func testTheHeaderNamesBothSidesOfTheMerge() {
        let g = gate(LandFixture.landable())
        XCTAssertEqual(g.kildName, "sidebar")
        XCTAssertEqual(g.base, "development", "the base comes from the report, not the kild")
    }

    // MARK: - Blocking

    /// `commits` empty is how the engine says "nothing to land" — there is no ahead/behind
    /// on this route. It is a refusal rather than a no-op, because it almost always means
    /// the wrong kild is selected.
    func testNothingToLandBlocks() {
        let g = gate(LandFixture.nothingToLand())
        XCTAssertFalse(g.canLand)
        XCTAssertTrue(g.checks.contains { $0.id == "position" && $0.blocks })
    }

    func testARefusedMergeBlocks() {
        XCTAssertFalse(gate(LandFixture.blocked()).canLand)
    }

    /// The engine's collision preview — this branch against its base. Distinct from the
    /// cross-kild derivation, and NOT marked derived, because the engine reported it.
    func testEngineReportedConflictingPathsBlockAndAreNotDerived() {
        let g = gate(LandFixture.blocked(collides: ["A.swift", "B.swift"]))
        let check = g.checks.first { $0.id == "conflicts" }
        XCTAssertEqual(check?.blocks, true)
        XCTAssertEqual(check?.derived, false)
        XCTAssertEqual(check?.text.contains("2 paths"), true)
    }

    /// Landing under a working agent races whatever it commits next.
    func testARunningAgentBlocks() {
        let g = gate(LandFixture.landable(), agents: [agent("coder")])
        XCTAssertFalse(g.canLand)
        XCTAssertTrue(g.checks.contains { $0.id == "agents" && $0.blocks })
    }

    func testAnIdleAgentDoesNotBlock() {
        XCTAssertTrue(gate(LandFixture.landable(), agents: [agent("c", idle: true)]).canLand)
    }

    func testAStoppedAgentDoesNotBlock() {
        XCTAssertTrue(
            gate(LandFixture.landable(), agents: [agent("c", stopped: true)]).canLand)
    }

    func testACrossKildCollisionBlocks() {
        let collision = Collision(other: "other", otherName: "context-bar", files: ["A.swift"])
        XCTAssertFalse(gate(LandFixture.landable(), collisions: [collision]).canLand)
    }

    /// The engine knows things helm never asked about, and its wording is the whole answer.
    func testTheEnginesOwnRefusalIsShownVerbatim() {
        let g = gate(LandFixture.blocked(reason: "base is not checked out in the main tree"))
        XCTAssertTrue(
            g.checks.contains {
                $0.text == "base is not checked out in the main tree" && $0.blocks
            })
    }

    /// A failed git probe returns safe defaults indistinguishable from a clean tree.
    func testAFailedGitProbeBlocks() {
        XCTAssertFalse(gate(LandFixture.landable(), git: GitFixture.failed()).canLand)
    }

    // MARK: - Two kinds of collision, told apart

    /// The gate carries both, and only one is derived. Conflating them would either credit
    /// helm's arithmetic to the engine or dismiss the engine's finding as a guess.
    func testTheTwoCollisionKindsAreDistinctChecks() {
        let cross = Collision(other: "other", otherName: "context-bar", files: ["X.swift"])
        let g = gate(LandFixture.blocked(collides: ["Y.swift"]), collisions: [cross])

        let engineSide = g.checks.first { $0.id == "conflicts" }
        let derivedSide = g.checks.first { $0.id == "collisions" }

        XCTAssertEqual(engineSide?.derived, false, "this branch vs its base — engine's")
        XCTAssertEqual(derivedSide?.derived, true, "kild vs kild — ours")
        XCTAssertNotNil(engineSide)
        XCTAssertNotNil(derivedSide)
    }

    func testEveryEngineReportedCheckIsNotMarkedDerived() {
        for check in gate(LandFixture.landable()).checks where check.id != "collisions" {
            XCTAssertFalse(check.derived, "\(check.id) comes from the engine, not from us")
        }
    }

    func testTheCrossKildCheckNamesTheOtherKildAndFileCount() {
        let collision = Collision(
            other: "other", otherName: "context-bar", files: ["A.swift", "B.swift"])
        let check = gate(LandFixture.landable(), collisions: [collision])
            .checks.first { $0.id == "collisions" }
        XCTAssertEqual(check?.text.contains("context-bar"), true)
        XCTAssertEqual(check?.text.contains("2 files"), true)
    }

    func testCollisionsAreCarriedForLinking() {
        let collision = Collision(other: "other-id", otherName: "context-bar", files: ["A"])
        XCTAssertEqual(
            gate(LandFixture.landable(), collisions: [collision]).collidesWith.first?.other,
            "other-id")
    }

    // MARK: - Wording

    /// The fallback wording, which no fixture had ever rendered.
    ///
    /// `report.branch` is genuinely nullable — a detached HEAD produces it — and it is read
    /// only on the `commits.isEmpty` path, so reaching it needs both conditions at once.
    /// Every fixture hardcoded a branch, so this string had never been produced.
    func testNothingToLandOnADetachedHeadStillReadsSensibly() {
        let g = gate(LandFixture.detachedHead())
        let position = g.checks.first { $0.id == "position" }
        XCTAssertEqual(position?.text, "nothing to land — no commits on this branch")
        XCTAssertEqual(position?.blocks, true)
    }

    func testSingularAndPluralCommitsBothRead() {
        XCTAssertEqual(
            gate(LandFixture.landable(commits: 1)).checks.first { $0.id == "position" }?.text,
            "1 commit to land into development")
        XCTAssertEqual(
            gate(LandFixture.landable(commits: 3)).checks.first { $0.id == "position" }?.text,
            "3 commits to land into development")
    }
}
