import XCTest

@testable import Helm

/// What the comment field quotes while the operator types a note (#210).
///
/// Each test drives the shipped `canvas-annotation.js` through `CanvasScriptRuntime` and puts what
/// it posted through the real gate, so a payload shape that drifts on either side fails here.
@MainActor
final class CanvasCommentFieldQuoteTests: XCTestCase {
    /// The stub's id-less block and a point inside it. Same fixture `CanvasAnchorTests` uses.
    private static let first = (text: "First unnamed block", at: (x: 100.0, y: 1240.0))

    func testASelectionQuotesItsText() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
        page.select(inBlockWithText: Self.first.text, text: "unnamed")
        page.mouse("mouseup", Self.first.at.x, Self.first.at.y)

        XCTAssertEqual(try quote(page), "unnamed")
    }

    /// A selection the gate admits and the decoder cannot anchor — longer than
    /// `maximumTextLength` — still opens the field, and the field has to say why a note cannot
    /// be written here instead of showing nothing.
    func testASelectionHelmCannotAnchorSaysSoInsteadOfShowingABlank() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
        let tooLong = String(repeating: "a", count: CanvasAnnotation.maximumTextLength + 1)
        page.select(id: "intro", text: tooLong)
        page.mouse("mouseup", 100, 110)

        XCTAssertEqual(try quote(page), "Nothing here helm can anchor a note to.")
    }

    private func quote(
        _ page: CanvasScriptRuntime, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let body = try XCTUnwrap(
            page.lastPosted, "the gesture posted nothing", file: file, line: line)
        guard case let .selected(selection) = try CanvasPageSelection.decode(body).get() else {
            XCTFail("the gate did not admit the mark as a selection", file: file, line: line)
            return ""
        }
        return CanvasCommentField.quote(for: selection)
    }
}
