import Foundation
import HelmWire
import XCTest

@testable import PocketKit

/// Pocket's chat (#625): a waiting prompt's choices read off its screen, and the transcript's pages
/// merged into one conversation.
final class PocketChatTests: XCTestCase {
    /// A screen benchd captured from the real CLI (`daemon/crates/benchd/screens/`).
    private func screen(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/crates/benchd/screens/\(name).txt")
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// Claude's permission prompt: its question, its four numbered options as the digits that pick
    /// them, and Esc because it says Esc cancels.
    func testClaudesPermissionPromptIsItsQuestionTheNumberedChoicesAndEsc() throws {
        let prompt = try XCTUnwrap(PromptChoices.read(try screen("claude-permission")))
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertEqual(prompt.choices.map(\.keys), ["1", "2", "3", "4"])
        XCTAssertEqual(prompt.choices.first?.label, "Yes")
        XCTAssertEqual(prompt.choices.last?.label, "No")
        XCTAssertTrue(prompt.canEscape)
    }

    /// codex's approval: the option behind the cursor mark counts too.
    func testCodexsApprovalIsItsQuestionAndItsChoices() throws {
        let prompt = try XCTUnwrap(PromptChoices.read(try screen("codex-approval")))
        XCTAssertEqual(prompt.question, "Would you like to run the following command?")
        XCTAssertEqual(prompt.choices.map(\.keys), ["1", "2", "3"])
        XCTAssertEqual(prompt.choices.first?.label, "Yes, proceed (y)")
        XCTAssertTrue(prompt.canEscape)
    }

    /// Claude's plan approval prints the plan, often numbered, right above its own options: the
    /// buttons are the prompt's options only, whose digits answer it.
    func testANumberedPlanAboveThePromptIsNotItsChoices() throws {
        let lines = [
            "Here is the plan:", "1. Read the file", "2. Edit the file", "3. Run tests",
            "Would you like to proceed?",
            "❯ 1. Yes, and auto-accept edits", "2. Yes, and manually approve edits",
            "3. No, keep planning",
        ]
        let prompt = try XCTUnwrap(PromptChoices.read(lines))
        XCTAssertEqual(prompt.question, "Would you like to proceed?")
        XCTAssertEqual(prompt.choices.map(\.keys), ["1", "2", "3"])
        XCTAssertEqual(prompt.choices.last?.label, "No, keep planning")
    }

    /// codex's hook review asks no question, and offers Esc only while its hint says so.
    func testAPromptWithoutAQuestionOrAnEscHint() throws {
        let lines = try screen("codex-hook-review")
        let prompt = try XCTUnwrap(PromptChoices.read(lines))
        XCTAssertNil(prompt.question)
        XCTAssertEqual(prompt.choices.map(\.keys), ["1", "2", "3"])
        XCTAssertTrue(prompt.canEscape)
        let hintless = lines.filter { !$0.contains("esc skip") }
        XCTAssertFalse(try XCTUnwrap(PromptChoices.read(hintless)).canEscape)
    }

    /// A screen with no numbered choices offers none: a working agent, or a menu moved by arrows,
    /// which the keys row answers.
    func testAScreenWithoutNumberedChoicesOffersNone() throws {
        XCTAssertNil(PromptChoices.read(try screen("claude-working")))
        XCTAssertNil(PromptChoices.read(try screen("pi-trust")))
        // One numbered line is a list item in a reply, not a choice.
        XCTAssertNil(PromptChoices.read(["Next:", "1. Merge #640", "> "]))
        // A label that merely holds the letters is not an Esc hint.
        let lines = ["Apply?", "1. Yes", "2. Edit src/descriptions.rs"]
        XCTAssertFalse(try XCTUnwrap(PromptChoices.read(lines)).canEscape)
        // Numbered lines of an agent's reply, far above the bottom, are not a prompt.
        let reply = ["Here is the plan:", "1. Read", "2. Write"] + Array(repeating: "x", count: 25)
        XCTAssertNil(PromptChoices.read(reply))
    }

    /// Pages merge into one conversation in transcript order, each entry once, however the pages
    /// overlap or arrive.
    func testPagesMergeInOrderEachEntryOnce() {
        func entry(_ index: Int) -> BenchLogEntry {
            BenchLogEntry(index: index, atMs: 0, kind: .agent, text: "\(index)")
        }
        var log = ChatLog()
        XCTAssertNil(log.newest)
        log.merge(BenchSessionLog(total: 10, entries: (7...9).map(entry)))
        log.merge(BenchSessionLog(total: 12, entries: (9...11).map(entry)))
        log.merge(BenchSessionLog(total: 12, entries: (4...6).map(entry)))
        XCTAssertEqual(log.entries.map(\.index), Array(4...11))
        XCTAssertEqual(log.newest, 11)
        XCTAssertEqual(log.oldest, 4)
        XCTAssertTrue(log.hasOlder)
        log.merge(BenchSessionLog(total: 12, entries: (0...3).map(entry)))
        XCTAssertFalse(log.hasOlder)
        // The file was rewritten shorter: following `after: 11` would bring nothing, ever.
        log.merge(BenchSessionLog(total: 5, entries: []))
        XCTAssertNil(log.newest, "what was read is dropped, so the next ask is the last page")
        log.merge(BenchSessionLog(total: 5, entries: (0...4).map(entry)))
        XCTAssertEqual(log.entries.map(\.index), Array(0...4))
    }

    /// A chat's preview is its last message, his or the agent's, never a tool line; it is unread
    /// while its index is past the last entry he had on screen.
    func testThePreviewIsTheLastMessageAndUnreadIsAReplyPastWhatHeRead() throws {
        let log = BenchSessionLog(
            total: 3,
            entries: [
                BenchLogEntry(index: 0, atMs: 1, kind: .user, text: "go"),
                BenchLogEntry(index: 1, atMs: 2, kind: .agent, text: "Done.\nDetails follow."),
                BenchLogEntry(index: 2, atMs: 3, kind: .tool, tool: "Bash", text: "ls"),
            ])
        let preview = try XCTUnwrap(ChatPreview(log))
        XCTAssertEqual(preview.text, "Done.")
        XCTAssertFalse(preview.mine)
        XCTAssertEqual(preview.atMs, 2)
        XCTAssertTrue(preview.isUnread(readThrough: nil), "never opened")
        XCTAssertTrue(preview.isUnread(readThrough: 0))
        XCTAssertFalse(preview.isUnread(readThrough: 1))
        XCTAssertFalse(preview.isUnread(readThrough: 2))
        let own = try XCTUnwrap(
            ChatPreview(
                BenchSessionLog(
                    total: 1, entries: [BenchLogEntry(index: 0, atMs: 1, kind: .user, text: "hi")]
                )))
        XCTAssertTrue(own.mine)
        XCTAssertFalse(own.isUnread(readThrough: nil), "his own message is never unread")
    }
}
