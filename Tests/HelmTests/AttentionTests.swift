import XCTest

@testable import Helm

/// The derivations helm makes on top of engine truth. Pure functions of wire values, so
/// none of this needs a running engine — which is the point of keeping them separable.
final class AttentionTests: XCTestCase {

    // MARK: helpers

    private func agent(
        _ handle: String,
        ownership: Ownership = .owned,
        idle: Bool? = nil,
        stopped: Bool? = nil
    ) -> Agent {
        Agent(handle: handle, ownership: ownership, idle: idle, stopped: stopped)
    }

    private func kild(
        _ name: String,
        id: String? = nil,
        agents: [Agent] = [],
        changed: [String]? = nil,
        orphan: Bool? = nil
    ) -> Kild {
        Kild(
            id: id ?? name,
            name: name,
            cwd: "/repo",
            agents: agents,
            orphan: orphan,
            git: changed.map { GitFixture.measured(changedFiles: $0) }
        )
    }

    // MARK: the decision itself

    /// `waiting` and `working` are stated separately rather than one negating the other,
    /// because they are NOT exhaustive — a stopped agent is neither.
    ///
    /// This was previously decided at six call sites: four spelled `isIdle && !isStopped`,
    /// and the land gate spelled its inverse independently. A condition added to "waiting"
    /// would have needed adding in four places and removing in a fifth, the other way
    /// round. These assertions pin the three-state relationship so the definitions cannot
    /// drift apart again.
    func testWaitingAndWorkingAreDistinctAndNotExhaustive() {
        let waiting = agent("a", idle: true)
        let working = agent("b")
        let stopped = agent("c", stopped: true)
        let stoppedWhileIdle = agent("d", idle: true, stopped: true)

        XCTAssertTrue(waiting.isWaiting); XCTAssertFalse(waiting.isWorking)
        XCTAssertFalse(working.isWaiting); XCTAssertTrue(working.isWorking)

        // The case that makes them non-exhaustive: over, not resting, not running.
        XCTAssertFalse(stopped.isWaiting); XCTAssertFalse(stopped.isWorking)
        XCTAssertFalse(stoppedWhileIdle.isWaiting)
        XCTAssertFalse(stoppedWhileIdle.isWorking)
    }

    /// No agent may be both at once — the land gate blocks on `isWorking` while the badge
    /// counts `isWaiting`, so an overlap would mean a kild that both demands attention and
    /// refuses to land for the same reason.
    func testNoAgentIsBothWaitingAndWorking() {
        for idle in [nil, true, false] as [Bool?] {
            for stopped in [nil, true, false] as [Bool?] {
                let a = Agent(handle: "x", ownership: .owned, idle: idle, stopped: stopped)
                XCTAssertFalse(
                    a.isWaiting && a.isWorking,
                    "idle=\(String(describing: idle)) stopped=\(String(describing: stopped))")
            }
        }
    }

    // MARK: waiting

    func testAnIdleAgentIsWaitingOnYou() {
        let kilds = [kild("a", agents: [agent("coder", idle: true)])]
        XCTAssertEqual(Attention.waitingCount(in: kilds), 1)
    }

    func testAWorkingAgentIsNotWaiting() {
        let kilds = [kild("a", agents: [agent("coder")])]
        XCTAssertEqual(Attention.waitingCount(in: kilds), 0)
    }

    /// `idle` absent means "not idle" — the engine omits the field rather than sending
    /// false, so unwrapping it as a boolean has to handle absence in one place.
    func testAbsentIdleIsNotWaiting() {
        XCTAssertFalse(agent("coder", idle: nil).isIdle)
    }

    /// A stopped agent's process is gone, so nobody can unblock it. Counting it would
    /// inflate the badge with agents no human action can help.
    func testAStoppedAgentIsNotWaitingEvenWhenIdle() {
        let kilds = [kild("a", agents: [agent("coder", idle: true, stopped: true)])]
        XCTAssertEqual(Attention.waitingCount(in: kilds), 0)
    }

    func testWaitingCountsAcrossEveryKild() {
        let kilds = [
            kild("a", agents: [agent("one", idle: true), agent("two")]),
            kild("b", agents: [agent("three", idle: true)]),
            kild("c", agents: [agent("four")]),
        ]
        XCTAssertEqual(Attention.waitingCount(in: kilds), 2)
    }

    /// Attached agents earn the badge too — an attached harness that drained an empty inbox
    /// is idle by the same definition, and is just as much waiting on you.
    func testAttachedAgentsCountToo() {
        let kilds = [kild("a", agents: [agent("honryo", ownership: .attached, idle: true)])]
        XCTAssertEqual(Attention.waitingCount(in: kilds), 1)
    }

    func testWaitingNamesBothTheKildAndTheAgent() {
        let kilds = [kild("sidebar", agents: [agent("reviewer", idle: true)])]
        let waiting = Attention.waiting(in: kilds)
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting.first?.kild.name, "sidebar")
        XCTAssertEqual(waiting.first?.agent.handle, "reviewer")
    }

    // MARK: collisions

    func testTwoKildsTouchingOneFileCollide() {
        let kilds = [
            kild("a", changed: ["Sidebar.swift", "Store.swift"]),
            kild("b", changed: ["Store.swift", "Other.swift"]),
        ]
        let collisions = Attention.collisions(among: kilds)
        XCTAssertEqual(collisions["a"]?.first?.files, ["Store.swift"])
    }

    /// A collision is a fact *between* two kilds, so each side must see it — the sidebar
    /// row and the land gate both read from their own kild's entry.
    func testCollisionsAreSymmetric() {
        let kilds = [
            kild("a", changed: ["Shared.swift"]),
            kild("b", changed: ["Shared.swift"]),
        ]
        let collisions = Attention.collisions(among: kilds)
        XCTAssertEqual(collisions["a"]?.first?.other, "b")
        XCTAssertEqual(collisions["b"]?.first?.other, "a")
    }

    func testDisjointKildsDoNotCollide() {
        let kilds = [
            kild("a", changed: ["One.swift"]),
            kild("b", changed: ["Two.swift"]),
        ]
        XCTAssertTrue(Attention.collisions(among: kilds).isEmpty)
    }

    func testAKildDoesNotCollideWithItself() {
        let kilds = [kild("a", changed: ["One.swift"])]
        XCTAssertTrue(Attention.collisions(among: kilds).isEmpty)
    }

    /// Orphans have no record and no `changedFiles`. Including them would mean deriving
    /// collisions from absent data.
    func testOrphansNeverCollide() {
        let kilds = [
            kild("live", changed: ["Shared.swift"]),
            kild("ghost", changed: ["Shared.swift"], orphan: true),
        ]
        XCTAssertTrue(Attention.collisions(among: kilds).isEmpty)
    }

    func testCollisionFilesAreSortedForStableRendering() {
        let kilds = [
            kild("a", changed: ["z.swift", "a.swift", "m.swift"]),
            kild("b", changed: ["m.swift", "a.swift", "z.swift"]),
        ]
        XCTAssertEqual(
            Attention.collisions(among: kilds)["a"]?.first?.files,
            ["a.swift", "m.swift", "z.swift"])
    }

    func testThreeWayCollisionReportsEachPairing() {
        let kilds = [
            kild("a", changed: ["Shared.swift"]),
            kild("b", changed: ["Shared.swift"]),
            kild("c", changed: ["Shared.swift"]),
        ]
        let collisions = Attention.collisions(among: kilds)
        XCTAssertEqual(collisions["a"]?.count, 2)
        XCTAssertEqual(collisions["b"]?.count, 2)
        XCTAssertEqual(collisions["c"]?.count, 2)
    }

    // MARK: grouping

    func testOrphansAreGroupedApartFromLiveKilds() {
        let kilds = [
            kild("live", agents: [agent("coder")]),
            kild("ghost", orphan: true),
        ]
        let grouped = Attention.grouped(kilds)
        XCTAssertEqual(grouped[.live]?.map(\.name), ["live"])
        XCTAssertEqual(grouped[.orphaned]?.map(\.name), ["ghost"])
    }

    /// The thing asking for you should never sit below something that isn't.
    func testKildsWithWaitingAgentsSortFirst() {
        let kilds = [
            kild("aaa", agents: [agent("coder")]),
            kild("zzz", agents: [agent("reviewer", idle: true)]),
        ]
        XCTAssertEqual(Attention.grouped(kilds)[.live]?.map(\.name), ["zzz", "aaa"])
    }

    func testKildsWithoutAttentionSortByName() {
        let kilds = [
            kild("charlie", agents: [agent("a")]),
            kild("alpha", agents: [agent("b")]),
            kild("bravo", agents: [agent("c")]),
        ]
        XCTAssertEqual(
            Attention.grouped(kilds)[.live]?.map(\.name),
            ["alpha", "bravo", "charlie"])
    }
}
