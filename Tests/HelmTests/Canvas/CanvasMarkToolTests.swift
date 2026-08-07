import XCTest

@testable import Helm

/// The tool declares the mark, so nothing has to infer it (#112). These pin the one thing
/// that can silently drift: the picker and the page agreeing on what a tool is called — now
/// by holding each tool and driving a gesture, rather than by looking for its token in the
/// script's text (#197).
final class CanvasMarkToolTests: XCTestCase {

    /// What the page does when each tool is held — one gesture per tool, and the response that
    /// names it. A token renamed on one side only leaves the picker working while the page
    /// silently does nothing, which is the exact silent shape this slice keeps producing.
    ///
    /// **`.read` is the one case this method cannot carry alone, and that is why the next one
    /// exists.** Reading posts nothing on purpose, and an unknown token also posts nothing —
    /// so "nothing was posted" cannot tell a working `.read` from a renamed one. What separates
    /// them is the *pointer*: an unknown token falls past the guard in `mousedown` and takes it.
    /// The two methods together cover all five, and neither does on its own.
    func testEveryToolTheScriptBranchesOnHasACase() throws {
        for tool in CanvasMarkTool.allCases {
            let page = try CanvasScriptRuntime()
            page.setTool(tool)

            let expected: String?
            switch tool {
            case .read:
                page.select(id: "intro", text: "Why this exists")
                page.mouse("mouseup", 100, 110)
                expected = nil
            case .text:
                page.select(id: "intro", text: "Why this exists")
                page.mouse("mouseup", 100, 110)
                expected = "selection"
            case .freehand:
                page.loop(around: (x: 10, y: 1390, width: 320, height: 50))
                expected = "enclosure"
            case .arrow:
                page.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))
                expected = "relation"
            case .point:
                page.tap(at: (x: 100, y: 110))
                expected = "point"
            }

            XCTAssertEqual(
                page.lastPosted?["kind"] as? String, expected,
                "holding \(tool.token) must make the page do what that tool names — a token "
                    + "the page does not know falls through to \"do nothing\", which is "
                    + "indistinguishable from a rename by eye")
            XCTAssertTrue(page.drainExceptions().isEmpty)
        }
    }

    /// **`CanvasMarkTool.draws` held to the script's own two literals, over `allCases`** (#302).
    ///
    /// `mousedown` asks `t === "read" || t === "text"` and returns; every other token reaches
    /// `e.preventDefault()`. `draws` is the Swift spelling of that same fact, and a JavaScript
    /// file cannot compile against a Swift enum — so a sixth tool added on one side only, or a
    /// case whose `draws` verdict disagrees with the guard, fails here rather than shipping as
    /// a canvas that either eats the operator's text selection or refuses to draw.
    ///
    /// It is also `.read`'s rename gate, per the method above: renamed in Swift alone, the page
    /// receives an unknown token, takes the pointer, and this fails on the first assertion.
    func testThePageTakesThePointerForExactlyTheToolsThatDraw() throws {
        for tool in CanvasMarkTool.allCases {
            let page = try CanvasScriptRuntime()
            page.setTool(tool)

            XCTAssertEqual(
                page.mouse("mousedown", 100, 1390), tool.draws,
                "\(tool.token): `draws` is \(tool.draws), so the page must "
                    + (tool.draws ? "take" : "leave") + " the browser's pointer")

            page.mouse("mousemove", 300, 1420)
            // One direction only, and deliberately: a tool that never took the pointer never
            // started a stroke, so it can have no ink. The converse is **not** true and must
            // not be asserted — `.point` takes the pointer and draws nothing until `mouseup`,
            // where its ring is. `CanvasAnnotationScriptTests` owns what each tool draws.
            if !tool.draws {
                XCTAssertFalse(
                    page.hasMarkLayer, "\(tool.token) never took the pointer, so it laid no ink")
            }
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

        XCTAssertFalse(highlight.hasMarkLayer, "and nothing was drawn on the way")
        XCTAssertTrue(highlight.drainExceptions().isEmpty)
    }

    /// The default is `.read`, on both sides of the seam. Swift's half is `CanvasModel`'s
    /// (`testACanvasNobodyHasTouchedIsReading`); this is the page's, which sets the global
    /// itself and is what a canvas gets before any tool is ever pushed.
    func testTheDefaultIsReadingRatherThanDrawing() throws {
        XCTAssertFalse(
            CanvasMarkTool.read.draws,
            "a canvas nobody has touched must behave exactly as an ordinary web page")

        let page = try CanvasScriptRuntime()
        XCTAssertFalse(
            page.mouse("mousedown", 100, 40),
            "no tool pushed yet: the browser keeps its pointer, so text still selects natively")
        page.mouse("mousemove", 100, 1410)
        page.mouse("mouseup", 100, 1410)

        XCTAssertFalse(page.hasMarkLayer)
        XCTAssertTrue(page.posted.isEmpty)
    }

    /// **Text still selects while reading — helm just does not read the result.** The `.read`
    /// assertions above are all about silence, and silence is also what helm would produce by
    /// cancelling the gesture outright, which would take native selection away and break
    /// copying a line out of an artifact. `preventDefault` is what separates the two, so it is
    /// asserted directly rather than inferred from the absence of a message.
    ///
    /// **`mousedown` is the whole of it**, and the release is deliberately not asserted here:
    /// the script never cancels a `mouseup` under any tool, so a passing assertion about one
    /// would measure nothing. A drag is claimed at the press or not at all.
    func testReadingLeavesTheBrowsersOwnTextSelectionAlone() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.read)

        XCTAssertFalse(
            page.mouse("mousedown", 100, 110),
            "cancelling here is what would stop a drag selecting text at all")
    }

    func testEveryDrawingToolIsDistinguishableInThePicker() {
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
            CanvasHTML.setMarkTool(.freehand, theme: .light)
                .contains("window.__helmMarkTool = \"freehand\";"))
    }
}
