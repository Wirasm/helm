import XCTest

@testable import Helm

/// Opening an agent's conversation — which source it reads, and what it does when that
/// source refuses.
final class AgentConversationTests: XCTestCase {

    private func scratch() -> UserDefaults {
        let suite = "helm.agent.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func kild(_ agents: [Agent]) -> Kild {
        Kild(id: "k", name: "k", cwd: "/repo", agents: agents)
    }

    private func message(_ seq: Int, from: String, to: [String], _ text: String) -> Message {
        Message(id: "m\(seq)", kildId: "k", from: from, to: to, text: text,
                ts: 1_785_180_000_000, seq: seq)
    }

    // MARK: - Source selection

    /// An owned agent reads its own session file.
    @MainActor
    func testAnOwnedAgentLoadsItsTranscript() async {
        let api = FakeKildAPI()
        api.transcriptResult = AgentTranscript(
            entries: [TranscriptEntry(role: "assistant", text: "done")], total: 1)
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)
        let agent = Agent(handle: "coder", ownership: .owned)

        await store.openAgent(agent, in: kild([agent]))

        XCTAssertEqual(store.agentLines.count, 1)
        XCTAssertNil(store.agentLinesError)
    }

    /// An attached agent has NO transcript. helm must read the message log instead — not
    /// try the transcript and fall back, which would send a request it knows will be
    /// refused and then render the refusal as an error.
    @MainActor
    func testAnAttachedAgentReadsTheLogAndNeverAsksForATranscript() async {
        let api = FakeKildAPI()
        api.failTranscript = .engine("agent @honryo has no pi session file (yet)")
        api.messageLog = [
            message(1, from: "honryo", to: ["coder"], "rebase first"),
            message(2, from: "coder", to: ["honryo"], "done"),
            message(3, from: "other", to: ["someone"], "unrelated"),
        ]
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)
        let agent = Agent(handle: "honryo", ownership: .attached)

        await store.openAgent(agent, in: kild([agent]))

        XCTAssertEqual(store.agentLines.count, 2, "both directions, and only this agent's")
        XCTAssertNil(
            store.agentLinesError,
            "the transcript refusal must never be reached, let alone surfaced")
    }

    /// A genuine transcript failure IS shown — the engine's words, not a generic message.
    @MainActor
    func testAnOwnedAgentsTranscriptErrorIsSurfaced() async {
        let api = FakeKildAPI()
        api.failTranscript = .engine("session file unreadable")
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)
        let agent = Agent(handle: "coder", ownership: .owned)

        await store.openAgent(agent, in: kild([agent]))

        XCTAssertTrue(store.agentLines.isEmpty)
        XCTAssertEqual(store.agentLinesError, "session file unreadable")
    }

    // MARK: - Selection lifecycle

    @MainActor
    func testClosingReturnsTheDockToTheKild() async {
        let api = FakeKildAPI()
        api.transcriptResult = AgentTranscript(
            entries: [TranscriptEntry(role: "user", text: "hi")], total: 1)
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)
        let agent = Agent(handle: "coder", ownership: .owned)

        await store.openAgent(agent, in: kild([agent]))
        XCTAssertEqual(store.selectedAgent, "coder")

        store.closeAgent()
        XCTAssertNil(store.selectedAgent)
        XCTAssertTrue(store.agentLines.isEmpty, "stale lines must not outlive the selection")
    }

    /// The agent selection is separate from the kild selection on purpose — the observe
    /// column already demonstrated what sharing one binding costs.
    @MainActor
    func testOpeningAnAgentDoesNotDisturbTheKildSelection() async {
        let api = FakeKildAPI()
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)
        store.selection = "k"
        let agent = Agent(handle: "coder", ownership: .owned)

        await store.openAgent(agent, in: kild([agent]))

        XCTAssertEqual(store.selection, "k", "the kild is still selected underneath")
        XCTAssertEqual(store.selectedAgent, "coder")
    }

    // MARK: - Sending

    /// Every message is addressed. There is no unlogged path to an agent.
    @MainActor
    func testSendingAddressesTheAgentExplicitly() async {
        let api = FakeKildAPI()
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)

        await store.send("rebase first", to: "coder", in: "k")

        XCTAssertEqual(api.sent.map(\.to), [["coder"]])
        XCTAssertEqual(api.sent.map(\.text), ["rebase first"])
    }
}
