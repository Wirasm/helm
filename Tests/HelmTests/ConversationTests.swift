import XCTest

@testable import Helm

/// Where an agent's tab reads from, and why the two answers are not the same view.
///
/// `ownership` picks the *source*, not just the level of detail. Asking the transcript route
/// about an attached agent is not a request that returns less — it is a request the engine
/// refuses, because there is no session file to read.
final class ConversationTests: XCTestCase {

    private func agent(_ handle: String, _ ownership: Ownership) -> Agent {
        Agent(handle: handle, ownership: ownership)
    }

    private func message(_ seq: Int, from: String, to: [String], _ text: String) -> Message {
        Message(
            id: "m\(seq)", kildId: "k", from: from, to: to, text: text,
            ts: 1_785_180_000_000, seq: seq)
    }

    // MARK: - Source selection

    func testAnOwnedAgentReadsItsTranscript() {
        XCTAssertEqual(Conversation.source(for: agent("coder", .owned)), .transcript)
    }

    /// Not "a sparser transcript" — a different place entirely. The engine has no session
    /// file for an attached agent and says so rather than returning an empty one.
    func testAnAttachedAgentReadsTheRoutedMessages() {
        XCTAssertEqual(Conversation.source(for: agent("honryo", .attached)), .routedMessages)
    }

    // MARK: - Owned: the transcript

    func testTranscriptTurnsBecomeLines() {
        let transcript = AgentTranscript(
            entries: [
                TranscriptEntry(role: "user", text: "do the thing"),
                TranscriptEntry(role: "assistant", text: "done", toolCalls: nil),
            ], total: 2)
        XCTAssertEqual(Conversation.lines(from: transcript).count, 2)
    }

    /// The turns that did the most work carry the least text. An assistant turn that only
    /// called tools has `text: ""`, so a renderer reading only `text` would drop exactly the
    /// informative ones — this is the real shape the engine sends.
    func testAToolOnlyTurnIsKeptEvenThoughItsTextIsEmpty() {
        let transcript = AgentTranscript(
            entries: [TranscriptEntry(role: "assistant", text: "", toolCalls: ["send"])],
            total: 1)
        let lines = Conversation.lines(from: transcript)
        XCTAssertEqual(lines.count, 1)
        guard case let .turn(_, _, _, tools) = lines[0] else { return XCTFail("expected a turn") }
        XCTAssertEqual(tools, ["send"])
    }

    func testATrulyEmptyTurnIsDropped() {
        let transcript = AgentTranscript(
            entries: [TranscriptEntry(role: "assistant", text: "", toolCalls: [])], total: 1)
        XCTAssertTrue(Conversation.lines(from: transcript).isEmpty)
    }

    /// An unrecognised role renders as itself. A role added engine-side is a rendering
    /// question, never a reason to fail the whole transcript.
    func testAnUnknownRoleIsCarriedThroughRatherThanRejected() {
        let transcript = AgentTranscript(
            entries: [TranscriptEntry(role: "reasoning", text: "hm")], total: 1)
        guard case let .turn(_, role, _, _) = Conversation.lines(from: transcript)[0] else {
            return XCTFail("expected a turn")
        }
        XCTAssertEqual(role, "reasoning")
    }

    // MARK: - Attached: the routed messages

    /// Both directions. A tab showing only what the agent said would omit the instructions
    /// it was answering, which is most of what makes a conversation readable.
    func testBothSentAndReceivedMessagesAppear() {
        let log = [
            message(1, from: "honryo", to: ["coder"], "rebase first"),
            message(2, from: "coder", to: ["honryo"], "done"),
        ]
        XCTAssertEqual(Conversation.lines(for: "honryo", from: log).count, 2)
    }

    func testMessagesForOtherAgentsAreExcluded() {
        let log = [
            message(1, from: "honryo", to: ["coder"], "for honryo's tab"),
            message(2, from: "coder", to: ["reviewer"], "not for honryo"),
        ]
        XCTAssertEqual(Conversation.lines(for: "honryo", from: log).count, 1)
    }

    func testAMessageAddressedToSeveralAgentsAppearsForEach() {
        let log = [message(1, from: "human", to: ["a", "b"], "both of you")]
        XCTAssertEqual(Conversation.lines(for: "a", from: log).count, 1)
        XCTAssertEqual(Conversation.lines(for: "b", from: log).count, 1)
    }

    /// Ordered by `seq`, never `ts`. A wall clock that moved backwards would silently
    /// reorder the conversation, and reordering a conversation changes what it says.
    func testOrderingIsBySeqNotByTimestamp() {
        // seq 9 carries a LATER wall-clock than seq 10 — an NTP correction or DST shift.
        // Sorting on `ts` would put them the wrong way round.
        let earlier = Message(
            id: "m9", kildId: "k", from: "a", to: ["b"], text: "ninth",
            ts: 9_999_999_999_999, seq: 9)
        let log = [message(10, from: "b", to: ["a"], "tenth"), earlier]

        let lines = Conversation.lines(for: "a", from: log)
        guard case let .message(_, _, _, first) = lines[0],
            case let .message(_, _, _, second) = lines[1]
        else { return XCTFail("expected messages") }
        XCTAssertEqual([first, second], [9, 10])
    }

    func testTheSenderIsCarriedSoTheTabCanAttributeIt() {
        let log = [message(1, from: "kild", to: ["claude"], "hello")]
        guard case let .message(from, _, _, _) = Conversation.lines(for: "claude", from: log)[0]
        else { return XCTFail("expected a message") }
        XCTAssertEqual(from, "kild")
    }

    // MARK: - Empty means different things

    /// Same emptiness, opposite meanings — and only one of them is worth waiting on. An
    /// empty owned transcript is "not yet"; an empty attached one is "never".
    func testEmptinessIsExplainedDifferentlyByOwnership() {
        XCTAssertEqual(Conversation.emptyExplanation(for: agent("c", .owned)), "no turns yet")
        XCTAssertTrue(
            Conversation.emptyExplanation(for: agent("h", .attached))
                .contains("cannot see inside it"))
    }
}
