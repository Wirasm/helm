import XCTest

@testable import Helm

/// The tool declares the mark, so nothing has to infer it (#112). These pin the one thing
/// that can silently drift: the picker and the page agreeing on what a tool is called — now
/// by holding each tool and driving a gesture, rather than by looking for its token in the
/// script's text (#197).
final class CanvasMarkToolTests: XCTestCase {

    func testEveryToolTheScriptBranchesOnHasACase() throws {
        // If a tool is renamed on one side only, the picker keeps working and the page
        // silently does nothing — the exact silent shape this slice keeps producing. Held for
        // real now rather than looked for in the text (#197): a token the page does not know
        // falls through to "do nothing", which is indistinguishable from a rename by eye and
        // not at all indistinguishable from one here.
        for tool in CanvasMarkTool.allCases {
            let page = try CanvasScriptRuntime()
            page.setTool(tool)
            page.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))

            XCTAssertFalse(
                page.posted.isEmpty,
                "the page never acts on \(tool.token), so holding it would do nothing")
        }
    }

    func testTheDefaultIsReadingRatherThanDrawing() throws {
        XCTAssertFalse(
            CanvasMarkTool.select.draws,
            "a canvas nobody has touched must behave exactly as it did before this slice")

        // And the page agrees without being told: no tool pushed yet, and a drag reports a
        // selection rather than drawing anything.
        let page = try CanvasScriptRuntime()
        page.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))

        XCTAssertFalse(page.hasMarkLayer)
        XCTAssertEqual(page.lastPosted?["kind"] as? String, "cleared")
    }

    func testEveryDrawingToolIsDistinguishableInThePicker() {
        let symbols = Set(CanvasMarkTool.allCases.map(\.symbol))
        XCTAssertEqual(
            symbols.count, CanvasMarkTool.allCases.count,
            "two tools sharing an icon is a picker you cannot read")
        XCTAssertTrue(CanvasMarkTool.allCases.allSatisfy { !$0.help.isEmpty })
    }

    func testSettingTheToolQuotesItsArgument() {
        // It is evaluated in the page, so the token has to arrive as a JS string rather than
        // a bare identifier — the difference between setting a tool and a ReferenceError.
        XCTAssertTrue(
            CanvasHTML.setMarkTool(.freehand).contains("window.__helmMarkTool = \"freehand\";"))
    }
}
