import XCTest

@testable import Helm

/// The land gate's rule, tested without a window.
///
/// Landing is the one action in the model that rewrites a branch other kilds measure
/// against, so "when is this allowed" needs to be checkable directly rather than inferred
/// from whether a button looks grey.
final class LandGateTests: XCTestCase {

    private func kild(
        _ name: String = "sidebar", base: String? = "development", agents: [Agent] = []
    ) -> Kild {
        Kild(id: name, name: name, cwd: "/repo", base: base, agents: agents)
    }

    private func agent(_ handle: String, idle: Bool? = nil, stopped: Bool? = nil) -> Agent {
        Agent(handle: handle, ownership: .owned, idle: idle, stopped: stopped)
    }

    private func gate(
        _ report: LandReport,
        collisions: [Collision] = [],
        agents: [Agent] = []
    ) -> LandGate {
        LandGate.make(
            kild: kild(agents: agents), report: report, collisions: collisions,
            runningAgents: agents)
    }

    private func clean() -> LandReport {
        LandReport(ok: true, ahead: 3, behind: 0, dirty: false, conflictsWithBase: false)
    }

    // MARK: - Allowing

    func testACleanKildAheadOfBaseCanLand() {
        XCTAssertTrue(gate(clean()).canLand)
    }

    func testTheHeaderNamesBothSidesOfTheMerge() {
        let g = gate(clean())
        XCTAssertEqual(g.kildName, "sidebar")
        XCTAssertEqual(g.base, "development")
    }

    // MARK: - Blocking

    /// Almost always means the wrong kild is selected, so it is a refusal rather than a
    /// no-op that silently succeeds.
    func testNothingToLandBlocks() {
        var report = clean()
        report.ahead = 0
        let g = gate(report)
        XCTAssertFalse(g.canLand)
        XCTAssertTrue(g.checks.contains { $0.id == "position" && $0.blocks })
    }

    func testConflictWithBaseBlocks() {
        var report = clean()
        report.conflictsWithBase = true
        XCTAssertFalse(gate(report).canLand)
    }

    /// Landing under a working agent races whatever it commits next.
    func testARunningAgentBlocks() {
        let g = gate(clean(), agents: [agent("coder")])
        XCTAssertFalse(g.canLand)
        XCTAssertTrue(g.checks.contains { $0.id == "agents" && $0.blocks })
    }

    /// Idle means the agent finished its turn — it is not going to commit underneath you.
    func testAnIdleAgentDoesNotBlock() {
        XCTAssertTrue(gate(clean(), agents: [agent("coder", idle: true)]).canLand)
    }

    func testAStoppedAgentDoesNotBlock() {
        XCTAssertTrue(gate(clean(), agents: [agent("coder", stopped: true)]).canLand)
    }

    func testACollisionBlocks() {
        let collision = Collision(other: "other", otherName: "context-bar", files: ["A.swift"])
        let g = gate(clean(), collisions: [collision])
        XCTAssertFalse(g.canLand)
    }

    /// The engine knows things helm never asked about, and its wording is the whole answer.
    func testTheEnginesOwnRefusalBlocksAndIsShownVerbatim() {
        var report = clean()
        report.ok = false
        report.error = "refusing: 3 commits not reachable from base"
        let g = gate(report)
        XCTAssertFalse(g.canLand)
        XCTAssertTrue(
            g.checks.contains {
                $0.text == "refusing: 3 commits not reachable from base" && $0.blocks
            })
    }

    // MARK: - Dirt is not a blocker

    /// The measured reason: 27 of 27 agent worktrees on the machine that ran this were
    /// dirty from provisioning litter written before any agent started. A guard that
    /// refused dirty trees would refuse every real kild — which is precisely how 116
    /// worktrees became permanently unreclaimable.
    func testADirtyTreeIsReportedButDoesNotBlock() {
        var report = clean()
        report.dirty = true
        let g = gate(report)
        XCTAssertTrue(g.canLand, "dirt is not authored work")
        XCTAssertEqual(g.checks.first { $0.id == "tree" }?.verdict, .info)
    }

    // MARK: - Derivation is labelled

    /// The most reassuring line on the most consequential screen. A reader has no other way
    /// to tell it from something the server vouched for.
    func testTheCollisionCheckIsMarkedDerived() {
        let check = gate(clean()).checks.first { $0.id == "collisions" }
        XCTAssertEqual(check?.derived, true)
    }

    func testEveryEngineReportedCheckIsNotMarkedDerived() {
        let g = gate(clean())
        for check in g.checks where check.id != "collisions" {
            XCTAssertFalse(check.derived, "\(check.id) comes from the engine, not from us")
        }
    }

    func testTheCollisionCheckNamesTheOtherKildAndFileCount() {
        let collision = Collision(
            other: "other", otherName: "context-bar", files: ["A.swift", "B.swift"])
        let check = gate(clean(), collisions: [collision]).checks.first {
            $0.id == "collisions"
        }
        XCTAssertEqual(check?.text.contains("context-bar"), true)
        XCTAssertEqual(check?.text.contains("2 files"), true)
    }

    /// The collisions are carried through so the view can render them as links — the fix
    /// for a collision is in the other kild, not this one.
    func testCollisionsAreCarriedForLinking() {
        let collision = Collision(other: "other-id", otherName: "context-bar", files: ["A"])
        XCTAssertEqual(gate(clean(), collisions: [collision]).collidesWith.first?.other,
                       "other-id")
    }

    // MARK: - Wording

    func testSingularAndPluralCommitsBothRead() {
        var one = clean()
        one.ahead = 1
        XCTAssertEqual(
            gate(one).checks.first { $0.id == "position" }?.text, "1 commit ahead, 0 behind")
        XCTAssertEqual(
            gate(clean()).checks.first { $0.id == "position" }?.text,
            "3 commits ahead, 0 behind")
    }

    /// A kild whose record is gone has no recorded base; the gate must still render rather
    /// than crash on the missing value.
    func testAKildWithNoRecordedBaseStillRenders() {
        let g = LandGate.make(
            kild: kild(base: nil), report: clean(), collisions: [], runningAgents: [])
        XCTAssertEqual(g.base, "base")
    }
}
