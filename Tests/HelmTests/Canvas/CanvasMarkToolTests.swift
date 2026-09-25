import XCTest

@testable import Helm

/// The tool declares the mark, so nothing has to infer it (#112). These pin the one thing
/// that can silently drift: the picker and the page agreeing on what a tool is called — by
/// holding each tool and driving a gesture, rather than by looking for its token in the
/// script's text (#197).
final class CanvasMarkToolTests: XCTestCase {

    /// What the page does when each tool is held. A `.text` token renamed on one side only
    /// leaves the picker working while the page silently marks nothing, which is the exact
    /// silent shape this slice keeps producing. (`.read` renamed alone is harmless: the page
    /// marks only on `text`, so every other token reads.)
    func testEveryToolTheScriptBranchesOnHasACase() throws {
        for tool in CanvasMarkTool.allCases {
            let page = try CanvasScriptRuntime()
            page.setTool(tool)
            page.select(id: "intro", text: "Why this exists")
            page.mouse("mouseup", 100, 110)

            let expected: String? =
                switch tool {
                case .read: nil
                case .text: "selection"
                }
            XCTAssertEqual(
                page.lastPosted?["kind"] as? String, expected,
                "holding \(tool.token) must make the page do what that tool names")
            XCTAssertTrue(page.drainExceptions().isEmpty)
        }
    }

    /// The whole of the behaviour change, in the operator's own words: *"I don't want the
    /// comment popup to appear just because I'm clicking, only when marking something."*
    ///
    /// A canvas nobody has touched interprets nothing — not the click, and **not the selection
    /// either**. Both halves are asserted, because the second is the one that was actually
    /// firing: a click that selected nothing already posted `cleared` and *closed* the field,
    /// and what opened it was any click that produced a selection — a double-click on a word,
    /// a stray drag.
    func testACanvasNobodyHasTouchedPostsNothingAtAll() throws {
        // A bare click, which used to post `{kind: "cleared"}` and close the notes drawer.
        let click = try CanvasScriptRuntime()
        click.mouse("mouseup", 100, 110)
        XCTAssertTrue(
            click.posted.isEmpty,
            "a click while reading must say nothing — a `cleared` closes the notes drawer")

        // And a real highlight, which used to open the comment field over it.
        let highlight = try CanvasScriptRuntime()
        highlight.select(id: "intro", text: "Why this exists")
        highlight.mouse("mouseup", 100, 110)
        XCTAssertTrue(
            highlight.posted.isEmpty,
            "selecting text while reading must not open the comment field (#302)")

        XCTAssertTrue(highlight.drainExceptions().isEmpty)
    }

    /// The default is `.read`, on both sides of the seam. Swift's half is `CanvasModel`'s
    /// (`testACanvasNobodyHasTouchedIsReading`); this is the page's, which sets the global
    /// itself and is what a canvas gets before any tool is ever pushed.
    func testTheDefaultIsReading() throws {
        let page = try CanvasScriptRuntime()
        XCTAssertFalse(
            page.mouse("mousedown", 100, 40),
            "no tool pushed yet: the browser keeps its pointer, so text still selects natively")
        page.mouse("mousemove", 100, 1410)
        page.mouse("mouseup", 100, 1410)

        XCTAssertTrue(page.posted.isEmpty)
    }

    /// **Text still selects — helm just does not read the result while reading.** The `.read`
    /// assertions above are all about silence, and silence is also what helm would produce by
    /// cancelling the gesture outright, which would take native selection away and break
    /// copying a line out of an artifact. `preventDefault` is what separates the two, so it is
    /// asserted directly rather than inferred from the absence of a message.
    ///
    /// **`mousedown` is the whole of it**, and the release is deliberately not asserted here:
    /// the script never cancels a `mouseup` under any tool, so a passing assertion about one
    /// would measure nothing. A drag is claimed at the press or not at all.
    ///
    /// Every tool, because since #385 no tool takes the pointer: a text mark *is* the browser's
    /// own selection.
    func testNoToolTakesTheBrowsersOwnTextSelectionAway() throws {
        for tool in CanvasMarkTool.allCases {
            let page = try CanvasScriptRuntime()
            page.setTool(tool)

            XCTAssertFalse(
                page.mouse("mousedown", 100, 110),
                "\(tool.token): cancelling here is what would stop a drag selecting text at all")
        }
    }

    func testEveryToolIsDistinguishableInThePicker() {
        let symbols = Set(CanvasMarkTool.allCases.map(\.symbol))
        XCTAssertEqual(
            symbols.count, CanvasMarkTool.allCases.count,
            "two tools sharing an icon is a picker you cannot read")
        XCTAssertTrue(CanvasMarkTool.allCases.allSatisfy { !$0.help.isEmpty })

        let helps = Set(CanvasMarkTool.allCases.map(\.help))
        XCTAssertEqual(
            helps.count, CanvasMarkTool.allCases.count,
            "nor is one where two buttons claim to do the same thing — `.read` and `.text` "
                + "were one case until #302 and are the pair most likely to be described alike")
    }

    func testSettingTheToolQuotesItsArgument() {
        // It is evaluated in the page, so the token has to arrive as a JS string rather than
        // a bare identifier — the difference between setting a tool and a ReferenceError.
        XCTAssertTrue(
            CanvasHTML.setMarkTool(.text, theme: .light)
                .contains("window.__helmMarkTool = \"text\";"))
    }
}
