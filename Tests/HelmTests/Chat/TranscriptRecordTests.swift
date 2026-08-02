import XCTest

@testable import Helm

/// The structural parse: which records are prose, which are the operator, and
/// which are the machine wearing the operator's voice.
///
/// Every case is built from the real record shapes measured across this repo's
/// 38 transcripts (17,166 records) — not invented ones.
final class TranscriptRecordTests: XCTestCase {
    private func record(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        let raw = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(raw as? [String: Any])
    }

    private func meanings(_ json: String) throws -> [TranscriptRecord] {
        TranscriptRecord.meanings(of: try record(json))
    }

    // MARK: - Assistant prose

    func testAssistantTextBlockIsProse() throws {
        let parsed = try meanings(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#)
        XCTAssertEqual(parsed, [.agentProse("Done.")])
    }

    /// The whole content filter, and the ticket's first acceptance rule: a tool
    /// call is activity, never content. It must not reach the prose column in any
    /// form — not collapsed, not greyed, absent.
    func testToolUseAndThinkingAreActivityNotProse() throws {
        let toolUse = try meanings(
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}"#
        )
        XCTAssertEqual(toolUse, [.agentActivity], "a tool call is a beat, never a line of prose")

        let thinking = try meanings(
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""}]}}"#)
        XCTAssertEqual(thinking, [.agentActivity])
    }

    /// 2.1.220 writes a signature and an empty string for thinking — there is no
    /// prose to render, and inventing some would be the view making things up.
    func testEmptyTextBlockIsNotProse() throws {
        let parsed = try meanings(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"   \n "}]}}"#)
        XCTAssertEqual(parsed, [.agentActivity])
    }

    /// Measured: assistant records carry exactly one block each. The format
    /// permits more, and each is its own beat.
    func testEveryBlockOfAnAssistantRecordIsItsOwnMeaning() throws {
        let parsed = try meanings(
            #"""
            {"type":"assistant","message":{"content":[
              {"type":"thinking","thinking":"x"},
              {"type":"text","text":"Here is why."},
              {"type":"tool_use","name":"Bash","input":{}}]}}
            """#)
        XCTAssertEqual(parsed, [.agentActivity, .agentProse("Here is why."), .agentActivity])
    }

    // MARK: - The operator

    func testBareStringUserRecordIsTheOperator() throws {
        let parsed = try meanings(#"{"type":"user","message":{"content":"fix the build"}}"#)
        XCTAssertEqual(parsed, [.operatorPrompt("fix the build")])
    }

    func testUserTextBlockIsTheOperator() throws {
        let parsed = try meanings(
            #"{"type":"user","message":{"content":[{"type":"text","text":"ship it"}]}}"#)
        XCTAssertEqual(parsed, [.operatorPrompt("ship it")])
    }

    /// A `user` record of nothing but `tool_result` is the agent's own work
    /// coming back. It is activity, and — the part that matters — it must not
    /// open a turn, or every tool call would split the conversation.
    func testToolResultUserRecordIsNotTheOperator() throws {
        let parsed = try meanings(
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#)
        XCTAssertEqual(parsed, [.machineTurn])
    }

    // MARK: - Machinery

    /// `isMeta` catches injections that carry no marker at all — measured at 301
    /// records ("Another Claude session sent a message: …", skill preambles).
    func testIsMetaRecordIsMachinery() throws {
        let parsed = try meanings(
            #"{"type":"user","isMeta":true,"message":{"content":"Base directory for this skill: /x"}}"#
        )
        XCTAssertEqual(parsed, [.machineTurn])
    }

    /// The other direction, and the bigger one: 1,126 marker-carrying records
    /// have `isMeta` absent. `<task-notification>` alone is 926 of them. Trusting
    /// `isMeta` alone styles the machine's words as the operator's.
    func testMarkerWithoutIsMetaIsStillMachinery() throws {
        for marker in [
            "task-notification", "command-name", "command-message",
            "local-command-stdout", "local-command-caveat", "bash-input", "bash-stdout",
            "system-reminder",
        ] {
            let json = """
                {"type":"user","message":{"content":"<\(marker)>hello</\(marker)>"}}
                """
            XCTAssertEqual(
                try meanings(json), [.machineTurn],
                "\(marker) is the machine talking, with no isMeta to say so")
        }
    }

    /// The set has grown twice already, so the rule is the tag's *shape* rather
    /// than a list. An opener nobody has seen yet must still be caught — a
    /// hard-coded list fails silently, which is the worst failure mode for this
    /// particular lie.
    func testUnknownLowercaseTagIsStillMachinery() throws {
        let parsed = try meanings(
            #"{"type":"user","message":{"content":"<some-future-marker>x</some-future-marker>"}}"#)
        XCTAssertEqual(parsed, [.machineTurn])
    }

    // MARK: - The false-positive direction

    /// The rule must never eat the operator's own words. Measured false positives
    /// across 2,535 human prose records: zero.
    func testOperatorProseIsNeverMistakenForMachinery() throws {
        let humanOpenings = [
            "fix the build please",
            "<- that one",
            "<3",
            "<Foo> is a type name",
            "< 5 seconds is fine",
            "<TODO> what goes here?",
            "<placeholder> — what should this say?",
            "<not closed> and the rest is prose",
        ]
        for text in humanOpenings {
            let json = try JSONSerialization.data(
                withJSONObject: ["type": "user", "message": ["content": text]])
            let raw = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: json) as? [String: Any])
            XCTAssertEqual(
                TranscriptRecord.meanings(of: raw), [.operatorPrompt(text)],
                "the operator wrote \(text) and must see it rendered as their own")
        }
    }

    /// The closing tag is what separates a wrapper from a human typing an angle
    /// bracket. All 1,209 measured machine records close their own tag.
    func testMarkerRequiresItsClosingTag() {
        XCTAssertEqual(
            TranscriptRecord.machineMarker(in: "<task-notification>x</task-notification>"),
            "task-notification")
        XCTAssertNil(
            TranscriptRecord.machineMarker(in: "<task-notification>x"),
            "an unclosed tag is prose that happens to start with a bracket")
    }

    /// Uppercase opens no marker: HTML and generics in prose are the operator's.
    func testUppercaseTagIsNotAMarker() {
        XCTAssertNil(TranscriptRecord.machineMarker(in: "<Array<Int>> is the type</Array<Int>>"))
    }

    // MARK: - Everything else

    /// A transcript carries fourteen record types; twelve of them are
    /// bookkeeping. None may become prose.
    func testBookkeepingRecordsAreIgnored() throws {
        for type in [
            "system", "attachment", "mode", "ai-title", "last-prompt", "permission-mode",
            "bridge-session", "queue-operation", "file-history-snapshot", "file-history-delta",
            "agent-name", "pr-link", "frame-link",
        ] {
            XCTAssertEqual(
                try meanings("{\"type\":\"\(type)\"}"), [.ignored],
                "\(type) has nothing to say to a reader")
        }
    }
}
