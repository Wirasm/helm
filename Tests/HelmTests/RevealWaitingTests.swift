import XCTest

@testable import Helm

/// The badge's follow-through.
///
/// `docs/escalation.md` asks for a count *and* a way to act on it: "the count is the entry
/// point, the list is the follow-through." A badge that reports a number and leaves you to
/// hunt has done half the job — and the half it skipped is the one that costs you time.
///
/// The selection logic lives in `RootView`, which no XCTest can reach, so these test the
/// decision it delegates: which kild `Attention.waiting` names first, and that the ordering
/// makes that a sensible destination.
final class RevealWaitingTests: XCTestCase {

    private func agent(_ handle: String, idle: Bool? = nil, stopped: Bool? = nil) -> Agent {
        Agent(handle: handle, ownership: .owned, idle: idle, stopped: stopped)
    }

    private func kild(_ name: String, agents: [Agent]) -> Kild {
        Kild(id: name, name: name, cwd: "/repo", agents: agents)
    }

    /// The destination must be a kild that is actually waiting — otherwise the badge sends
    /// you somewhere with nothing to answer.
    func testTheFirstWaitingEntryNamesAKildWithAWaitingAgent() {
        let kilds = [
            kild("quiet", agents: [agent("a")]),
            kild("asking", agents: [agent("b", idle: true)]),
        ]
        let first = Attention.waiting(in: kilds).first
        XCTAssertEqual(first?.kild.name, "asking")
        XCTAssertEqual(first?.agent.handle, "b")
    }

    /// Grouping sorts waiting kilds first, so "the first waiting entry" and "the top of the
    /// column" are the same kild. If those diverged the badge would scroll you somewhere
    /// other than where the eye already is.
    func testTheColumnOrdersTheDestinationFirst() {
        let kilds = [
            kild("aaa-quiet", agents: [agent("a")]),
            kild("zzz-asking", agents: [agent("b", idle: true)]),
        ]
        let live = Attention.grouped(kilds)[.live] ?? []
        let firstWaiting = Attention.waiting(in: kilds).first

        XCTAssertEqual(live.first?.name, "zzz-asking", "sorted above the alphabetically-first")
        XCTAssertEqual(live.first?.id, firstWaiting?.kild.id, "and it is the same kild")
    }

    /// A stopped agent is not a destination. Its process is gone, so arriving there offers
    /// nothing to do — and the badge does not count it either, so the two must agree.
    func testAStoppedAgentIsNeverTheDestination() {
        let kilds = [kild("over", agents: [agent("a", idle: true, stopped: true)])]
        XCTAssertNil(Attention.waiting(in: kilds).first)
        XCTAssertEqual(Attention.waitingCount(in: kilds), 0, "badge and destination agree")
    }

    /// With nothing waiting there is no destination — and the badge is absent, so nothing
    /// can be clicked. Asserting both together is what keeps them consistent.
    func testNothingWaitingMeansNoBadgeAndNoDestination() {
        let kilds = [kild("busy", agents: [agent("a")])]
        XCTAssertEqual(Attention.waitingCount(in: kilds), 0)
        XCTAssertNil(Attention.waiting(in: kilds).first)
    }

    /// The destination is drawn from the LIVE group. A waiting agent is never in the
    /// archive, so revealing must not land on History and show an empty answer to a live
    /// question.
    func testOrphansAreNotDestinations() {
        var orphan = kild("ghost", agents: [])
        orphan.orphan = true
        let kilds = [orphan, kild("asking", agents: [agent("b", idle: true)])]

        let live = Attention.grouped(kilds)[.live] ?? []
        XCTAssertEqual(live.map(\.name), ["asking"], "an orphan has no agents to wait on you")
        XCTAssertEqual(Attention.waiting(in: live).first?.kild.name, "asking")
    }
}
