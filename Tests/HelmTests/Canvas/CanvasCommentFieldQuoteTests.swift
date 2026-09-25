import XCTest

@testable import Helm

/// What the comment field quotes while the operator types a note, for every mark the page can
/// make (#210).
///
/// The quote read a top-level `text` field and nothing else. Only a text selection and a tap post
/// one, so an arrow or a circle opened the field with a quote glyph and a blank after it. The
/// note itself was right, because `CanvasAnnotation.decode` resolved the real anchors, but the
/// operator could not see what they were commenting on.
///
/// Each test drives the shipped `canvas-annotation.js` through `CanvasScriptRuntime` and puts what
/// it posted through the real gate, so a payload shape that drifts on either side fails here.
@MainActor
final class CanvasCommentFieldQuoteTests: XCTestCase {
    /// The stub's id-less blocks and a point inside each. Same fixture `CanvasAnchorTests` uses.
    private static let first = (text: "First unnamed block", at: (x: 100.0, y: 1240.0))
    private static let second = (text: "Second unnamed block", at: (x: 100.0, y: 1310.0))
    /// Right of `#content`, where the stub lays nothing out: blank space.
    private static let blank = (x: 900.0, y: 1240.0)

    func testASelectionQuotesItsText() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
        page.select(inBlockWithText: Self.first.text, text: "unnamed")
        page.mouse("mouseup", Self.first.at.x, Self.first.at.y)

        XCTAssertEqual(try quote(page), "unnamed")
    }

    func testATapQuotesWhatItLandedOn() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.point)
        page.tap(at: Self.first.at)

        XCTAssertEqual(try quote(page), Self.first.text)
    }

    func testAnArrowQuotesBothEnds() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.arrow)
        page.drag(from: Self.first.at, to: Self.second.at)

        XCTAssertEqual(try quote(page), "\(Self.first.text) → \(Self.second.text)")
    }

    /// An arrow into blank space is "add a node here", a real mark. The empty end is named
    /// rather than dropped, as the note heading does.
    func testAnArrowIntoBlankSpaceNamesTheEmptyEnd() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.arrow)
        page.drag(from: Self.first.at, to: Self.blank)

        XCTAssertEqual(try quote(page), "\(Self.first.text) → empty space")
    }

    func testACircleQuotesEverythingItEncloses() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.freehand)
        page.loop(around: (x: 10, y: 1210, width: 720, height: 120))

        XCTAssertEqual(try quote(page), "\(Self.first.text), \(Self.second.text)")
    }

    /// The page posts an empty circle on purpose, so the refusal is visible. The field opens,
    /// and it has to say why a note cannot be anchored here instead of showing nothing.
    func testACircleAroundNothingSaysSoInsteadOfShowingABlank() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.freehand)
        page.loop(around: (x: 100, y: 1600, width: 100, height: 60))

        XCTAssertFalse(
            try quote(page).isEmpty, "a mark with nothing under it must say so, not show a blank")
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
