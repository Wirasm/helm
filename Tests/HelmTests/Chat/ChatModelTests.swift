import XCTest

@testable import Helm

/// The model's rules: turn structure, which block is the turn's last word, and
/// the gate that makes a composer safe at all.
///
/// Everything runs against fixture directories — the chat face must be testable
/// on a machine that has never run Claude Code, and with no pty.
@MainActor
final class ChatModelTests: XCTestCase {
    private var registry: URL!
    private var projects: URL!
    private var model: ChatModel!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-chat-tests-\(UUID().uuidString)")
        registry = base.appendingPathComponent("sessions")
        projects = base.appendingPathComponent("projects")
        for url in [registry!, projects!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        model = ChatModel(registryRoot: registry, transcriptRoot: projects)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: registry.deletingLastPathComponent())
        registry = nil
        projects = nil
        model = nil
    }

    // MARK: - The composer gate

    /// **The one rule the composer's safety rests on.** `idle` and nothing else.
    ///
    /// Note `waiting` — an agent blocked on a permission prompt — must refuse.
    /// That is precisely the case where prose is silently destructive: #29
    /// measured `yes go ahead that is fine` having its `y` approve and run a
    /// network command, with no error and nothing to undo.
    func testComposerOpensOnlyWhenTheAgentIsIdle() {
        XCTAssertFalse(gate(nil), "no agent at all is not a licence to type")
        XCTAssertTrue(gate(.idle))
        XCTAssertFalse(gate(.busy))
        XCTAssertFalse(gate(.waiting), "blocked on a prompt — this is the destructive case")
        XCTAssertFalse(gate(.shell), "a command has the pty")
    }

    /// **`canSend` must not be spelled `!isWorking`.** `AgentStatus.isWorking` is
    /// the *board's* collapse, which folds `waiting` in with `idle` because the
    /// board asks "does this need you?". Reusing it here would open the composer
    /// on exactly the case it exists to refuse.
    func testWaitingIsWorkingForTheTickerButClosedForTheComposer() {
        let waiting = write(pid: 4242, status: "waiting")
        model.tick(foregroundPid: waiting)

        XCTAssertTrue(model.isWorking, "mid-turn: the tape keeps running")
        XCTAssertFalse(model.canSend, "and the box stays shut")
        XCTAssertFalse(
            AgentStatus.waiting.isWorking,
            "the board's collapse disagrees on purpose — do not reuse it for the tape")
    }

    private func gate(_ status: AgentStatus?) -> Bool {
        guard let status else { return false }
        let pid = write(pid: 5150, status: status.rawValue)
        let fresh = ChatModel(registryRoot: registry, transcriptRoot: projects)
        fresh.tick(foregroundPid: pid)
        return fresh.canSend
    }

    // MARK: - Reading a conversation

    func testRendersOperatorTurnsAndAgentProseInFileOrder() {
        let pid = write(
            pid: 900, status: "idle",
            transcript: [
                user("plan the migration"),
                assistantText("Let me look at the schema."),
                toolResult(),
                assistantText("Here is the plan."),
            ])
        model.tick(foregroundPid: pid)

        XCTAssertEqual(
            model.entries.map(\.voice), [.operatorTurn, .agent, .agent],
            "the operator's own turn renders — otherwise it is half a conversation")
        XCTAssertEqual(
            model.entries.map(\.text),
            ["plan the migration", "Let me look at the schema.", "Here is the plan."])
    }

    /// The ticket's parsing rule, as a position rather than a pattern: the last
    /// `text` block of the last assistant record of the turn.
    func testTheTurnsLastWordIsItsLastProseBlock() {
        let pid = write(
            pid: 901, status: "idle",
            transcript: [
                user("one"),
                assistantText("thinking out loud"),
                assistantText("THE ANSWER"),
            ])
        model.tick(foregroundPid: pid)

        let answers = model.entries.filter { model.answers.contains($0.id) }
        XCTAssertEqual(answers.map(\.text), ["THE ANSWER"])
    }

    /// Until the agent stops, no block is the turn's last word yet — promoting
    /// one would be the view claiming an ending that has not happened.
    func testNoAnswerIsPromotedWhileTheAgentIsStillWorking() {
        let pid = write(
            pid: 902, status: "busy",
            transcript: [user("go"), assistantText("working on it")])
        model.tick(foregroundPid: pid)

        XCTAssertTrue(model.isWorking)
        XCTAssertTrue(model.answers.isEmpty, "the turn has not ended, so it has no last word")
    }

    /// Each turn keeps its own answer once it is over.
    func testEachFinishedTurnKeepsItsOwnAnswer() {
        let pid = write(
            pid: 903, status: "idle",
            transcript: [
                user("first"), assistantText("A1"),
                user("second"), assistantText("B1"), assistantText("B2"),
            ])
        model.tick(foregroundPid: pid)

        let answers = Set(model.entries.filter { model.answers.contains($0.id) }.map(\.text))
        XCTAssertEqual(answers, ["A1", "B2"])
    }

    /// A tool result is the agent's own work returning. If it opened a turn,
    /// every tool call would split the conversation in two.
    func testToolResultsDoNotOpenATurn() {
        let pid = write(
            pid: 904, status: "idle",
            transcript: [
                user("go"), assistantText("A"), toolResult(), assistantText("B"),
            ])
        model.tick(foregroundPid: pid)

        XCTAssertEqual(Set(model.entries.map(\.turn)).count, 1, "one prompt, one turn")
    }

    /// Roughly a third of `user` records are machine-authored. Rendering them as
    /// the operator is the view putting words in their mouth.
    func testMachineryNeverRendersAsTheOperator() {
        let pid = write(
            pid: 905, status: "idle",
            transcript: [
                user("real prompt"),
                #"{"type":"user","message":{"content":"<task-notification>x</task-notification>"}}"#,
                #"{"type":"user","isMeta":true,"message":{"content":"Base directory for this skill: /x"}}"#,
                assistantText("ok"),
            ])
        model.tick(foregroundPid: pid)

        XCTAssertEqual(
            model.entries.filter { $0.voice == .operatorTurn }.map(\.text), ["real prompt"])
    }

    // MARK: - Secrets

    func testProseIsMaskedOnTheWayIn() {
        // Assembled rather than written out: a credential-shaped literal is a
        // credential to a secret scanner, whatever file it sits in.
        let secret = "sk-" + String(repeating: "9", count: 20)
        let pid = write(
            pid: 906, status: "idle",
            transcript: [user("go"), assistantText("your key is \(secret) ok")])
        model.tick(foregroundPid: pid)

        let text = model.entries.last?.text ?? ""
        XCTAssertFalse(text.contains(secret), "a chat view makes it selectable forever")
        XCTAssertTrue(text.contains(SecretMask.placeholder))
        XCTAssertEqual(model.maskedCount, 1, "the count is surfaced — a silent mask is its own lie")
    }

    // MARK: - Nothing to read

    /// The toggle is always pressable, so every empty state has to name itself.
    /// An empty pane is the failure here: a miss and a silence look identical,
    /// and only one of them is worth telling the operator about.
    ///
    /// A fresh model per case on purpose — rediscovery is throttled to once a
    /// second, so reusing one would silently test the previous answer.
    func testEveryEmptyStateNamesItsReason() {
        assertUnavailable("no process in the terminal") { $0.tick(foregroundPid: nil) }
        assertUnavailable("a pid with no registry row") { $0.tick(foregroundPid: 999_999) }
        assertUnavailable("an agent that has not written a transcript yet") { fresh in
            fresh.tick(foregroundPid: self.write(pid: 907, status: "busy"))
        }
    }

    private func assertUnavailable(
        _ what: String, line: UInt = #line, _ act: (ChatModel) -> Void
    ) {
        let fresh = ChatModel(registryRoot: registry, transcriptRoot: projects)
        act(fresh)
        guard case .unavailable(let reason) = fresh.source else {
            return XCTFail("\(what) left the pane with nothing to say", line: line)
        }
        XCTAssertFalse(reason.isEmpty, "\(what) needs a reason on screen", line: line)
    }

    // MARK: - Fixtures

    private func user(_ text: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["type": "user", "message": ["content": text]])
        return String(decoding: data, as: UTF8.self)
    }

    private func assistantText(_ text: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: [
                "type": "assistant",
                "message": ["content": [["type": "text", "text": text]]],
            ])
        return String(decoding: data, as: UTF8.self)
    }

    private func toolResult() -> String {
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
    }

    /// Writes a registry row (and optionally its transcript) and returns the pid,
    /// so a test reads as "this is what is on disk, now tick".
    @discardableResult
    private func write(pid: pid_t, status: String, transcript: [String] = []) -> pid_t {
        let sessionId = "session-\(pid)"
        let cwd = "/tmp/ws-\(pid)"
        let row = """
            {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"\(cwd)",\
            "status":"\(status)","version":"2.1.220"}
            """
        try! row.write(
            to: registry.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)

        guard !transcript.isEmpty else { return pid }
        let directory = projects.appendingPathComponent(
            TranscriptLocator.directoryName(for: cwd))
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! (transcript.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("\(sessionId).jsonl"),
            atomically: true, encoding: .utf8)
        return pid
    }
}
