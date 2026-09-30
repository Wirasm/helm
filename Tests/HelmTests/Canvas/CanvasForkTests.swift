import HelmWire
import XCTest

@testable import Helm

/// "Ask a fork" (#535) on its own: which conversation a mark can be asked of, and the prompt the
/// fork starts with. `WorkbenchAskForkTests` drives the same rules through a mark and benchd.
final class CanvasForkTests: XCTestCase {
    private let claude = BenchDocument.Agent(
        command: "claude", session: "4b1c9e0f-2a3d-4c5e-8f60-718293a4b5c6", cwd: "/work")

    func testOnlyAClaudeConversationThatOpenedTheCanvasCanBeForked() {
        let opener = UUID()
        XCTAssertEqual(CanvasForkRoute.route(opener: opener, author: claude), .fork(claude))
        XCTAssertEqual(
            CanvasForkRoute.route(opener: nil, author: nil),
            .unavailable(CanvasForkRoute.noOpener))
        guard
            case let .unavailable(noRecord) = CanvasForkRoute.route(opener: opener, author: nil),
            case let .unavailable(pi) = CanvasForkRoute.route(
                opener: opener, author: .init(command: "pi", session: "p-1", cwd: "/work")),
            case let .unavailable(codex) = CanvasForkRoute.route(
                opener: opener, author: .init(command: "codex", session: "t-1", cwd: "/work"))
        else { return XCTFail("only claude forks") }
        XCTAssertTrue(noRecord.contains("no recorded conversation"), noRecord)
        XCTAssertTrue(pi.contains("Opened by pi"), pi)
        XCTAssertTrue(codex.contains("Opened by codex"), codex)
    }

    func testThePromptNamesTheFileTheLinesTheMarkAndTheQuestion() {
        let source = "# Plan\n\nRetry at most 4 times.\nThen give up.\n"
        let prompt = CanvasForkPrompt.text(
            canvas: URL(fileURLWithPath: "/work/plan.md"), source: source,
            marked: "Retry at most 4 times.\nThen give up.", question: "Why four?")
        XCTAssertTrue(prompt.contains("You are a fork"), prompt)
        XCTAssertTrue(prompt.contains("Do not continue its task, and do not edit any files"))
        XCTAssertTrue(prompt.contains("File: /work/plan.md"))
        XCTAssertTrue(prompt.contains("Lines: 3-4"), prompt)
        XCTAssertTrue(
            prompt.contains("```text\nRetry at most 4 times.\nThen give up.\n```"), prompt)
        XCTAssertTrue(prompt.contains("The operator's question:\n\nWhy four?"))
        XCTAssertTrue(prompt.contains("If you do not know, say so"))
    }

    func testAMarkNotInTheFileVerbatimSaysSoRatherThanGuessingLines() {
        let prompt = CanvasForkPrompt.text(
            canvas: URL(fileURLWithPath: "/work/plan.md"), source: "Retry **at most** 4 times.",
            marked: "Retry at most 4 times.", question: "Why?")
        XCTAssertTrue(prompt.contains("Lines: not found"), prompt)
        XCTAssertEqual(CanvasForkPrompt.lines(of: "Then", in: "one\ntwo\nThen"), 3...3)
    }

    func testTheFenceIsLongerThanAnyBacktickRunInTheMark() {
        XCTAssertEqual(CanvasForkPrompt.fence(for: "plain"), "```")
        XCTAssertEqual(CanvasForkPrompt.fence(for: "a ```swift``` block"), "````")
    }

    func testOnlyAForkThatStartedLeavesTheClipboardAlone() {
        XCTAssertFalse(CanvasForkDelivery.asked(handle: "s7").copiesToClipboard)
        XCTAssertTrue(CanvasForkDelivery.unavailable("x").copiesToClipboard)
        XCTAssertTrue(CanvasForkDelivery.failed("x").copiesToClipboard)
        XCTAssertTrue(
            CanvasForkDelivery.asked(handle: "s7").receipt(sidecar: "plan.notes.md")
                .contains("s7"))
        XCTAssertTrue(
            CanvasForkDelivery.failed("refused").receipt(sidecar: "plan.notes.md")
                .contains("copied"))
    }
}
