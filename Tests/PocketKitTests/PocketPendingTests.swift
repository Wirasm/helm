import Foundation
import HelmWire
import XCTest

@testable import PocketKit

/// What he sent but the agent has not taken yet (operator, 2026-10-05): the harnesses write a
/// message they queue while busy to the transcript only when they take it, so Pocket shows it at
/// once and lets the transcript take its place, once, when it arrives.
final class PocketPendingTests: XCTestCase {
    private func log(_ entries: [(Int, BenchLogEntry.Kind, String)]) -> ChatLog {
        var log = ChatLog()
        log.merge(
            BenchSessionLog(
                total: (entries.map(\.0).max() ?? -1) + 1,
                entries: entries.map { BenchLogEntry(index: $0.0, atMs: 0, kind: $0.1, text: $0.2) }
            ))
        return log
    }

    /// A message stays until a prompt with its text arrives after the entry he had when he sent
    /// it; the agent's reply quoting it, or the same words said earlier, do not take its place.
    func testASentMessageStaysUntilTheTranscriptHasIt() {
        var pending = ChatPending()
        pending.add("ship it", after: 4)
        pending.reconcile(log([(3, .user, "ship it"), (4, .agent, "Done.")]))
        XCTAssertEqual(pending.messages.map(\.text), ["ship it"], "said before he sent it")
        pending.reconcile(log([(5, .agent, "ship it")]))
        XCTAssertEqual(pending.messages.map(\.text), ["ship it"], "the agent's words")
        pending.reconcile(log([(6, .user, "  ship it\n")]))
        XCTAssertTrue(pending.messages.isEmpty)
    }

    /// The same words sent twice are two messages: one prompt in the transcript takes the place
    /// of one of them, however often the log is read again.
    func testTheSameWordsSentTwiceAreTwoMessages() {
        var pending = ChatPending()
        pending.add("again", after: 1)
        pending.add("again", after: 1)
        let arrived = log([(2, .user, "again")])
        pending.reconcile(arrived)
        pending.reconcile(arrived)
        XCTAssertEqual(pending.messages.map(\.text), ["again"])
        pending.reconcile(log([(2, .user, "again"), (3, .user, "again")]))
        XCTAssertTrue(pending.messages.isEmpty)
    }

    /// A message pasted into a prompt that already held what he typed is recorded as both
    /// (Claude Code 2.1.289): the prompt holding his message as whole lines takes its place. One
    /// that only holds his words inside a line does not.
    func testAPromptHoldingTheMessageAsItsLinesTakesItsPlace() {
        var pending = ChatPending()
        pending.add("Merge \n3767 start the follow up\n\nD1 a\n\n", after: 2)
        pending.reconcile(log([(3, .user, "not D1 a only")]))
        XCTAssertEqual(pending.messages.count, 1, "his words inside a line")
        pending.reconcile(
            log([(4, .user, "half typed on the mac\n\n\nMerge \n3767 start the follow up\n\nD1 a")])
        )
        XCTAssertTrue(pending.messages.isEmpty)
    }

    /// An idle agent takes a message at once. One still waiting after the agent has sat idle for
    /// `landing` since the last send did not land, and says so instead of waiting as queued for
    /// good; while the agent works it waits.
    func testAMessageAnIdleAgentNeverTookSaysSo() {
        let start = Date(timeIntervalSince1970: 1000)
        var pending = ChatPending()
        pending.agent(busy: false, at: start)
        pending.add("hello", after: 1)
        pending.agent(busy: true, at: start + 600)
        XCTAssertEqual(pending.messages.map(\.notTaken), [false], "queued behind a long turn")
        pending.agent(busy: false, at: start + 601)
        pending.agent(busy: false, at: start + 601 + ChatPending.landing - 1)
        XCTAssertEqual(pending.messages.map(\.notTaken), [false], "idle, not for long yet")
        pending.agent(busy: false, at: start + 601 + ChatPending.landing)
        XCTAssertEqual(pending.messages.map(\.notTaken), [true])
        pending.reconcile(log([(2, .user, "hello")]))
        XCTAssertTrue(pending.messages.isEmpty, "it landed late after all")

        pending.add("again", after: 2)
        pending.agent(busy: false, at: start + 700)
        pending.agent(busy: false, at: start + 700 + ChatPending.landing - 1)
        XCTAssertEqual(pending.messages.map(\.notTaken), [false], "idle before it was sent")
    }

    /// One benchd may have taken without answering is kept, and says so.
    func testAMessageThatMayNotHaveGoneSaysSo() {
        var pending = ChatPending()
        pending.add("maybe", after: nil, maybeSent: true)
        XCTAssertEqual(pending.messages.first?.maybeSent, true)
        pending.reconcile(log([(0, .user, "maybe")]))
        XCTAssertTrue(pending.messages.isEmpty)
    }

    /// A rewritten transcript numbers its entries again: what was matched and where each message
    /// was sent from no longer hold, so the prompt that arrives next still takes its place.
    func testARewrittenTranscriptForgetsThePlaces() {
        var pending = ChatPending()
        pending.add("one", after: 40)
        pending.add("two", after: 40)
        pending.reconcile(log([(41, .user, "one")]))
        XCTAssertEqual(pending.messages.map(\.text), ["two"])
        pending.forgetPlaces()
        pending.reconcile(log([(3, .user, "two")]))
        XCTAssertTrue(pending.messages.isEmpty)
    }

    /// The window a chat opens with may begin after a message was sent: the chat must read from
    /// where the oldest message was sent to find its prompt.
    func testWhatTheWindowCannotShowIsAskedFor() {
        var pending = ChatPending()
        XCTAssertNil(pending.unseen(in: log([(50, .agent, "x")])))
        pending.add("early", after: 9)
        pending.add("later", after: 48)
        XCTAssertEqual(pending.unseen(in: log([(50, .agent, "x")])), 9)
        XCTAssertNil(pending.unseen(in: log([(10, .agent, "x"), (11, .agent, "y")])))
    }
}
