import XCTest

@testable import Helm

/// The tool declares the mark, so nothing has to infer it (#112). These pin the one thing
/// that can silently drift: the picker and the page agreeing on what a tool is called.
final class CanvasMarkToolTests: XCTestCase {

    func testEveryToolTheScriptBranchesOnHasACase() {
        // The script's branches are string literals. If a tool is renamed on one side only,
        // the picker keeps working and the page silently does nothing — the exact silent
        // shape this slice keeps producing.
        let script = CanvasHTML.annotationScript()

        for tool in CanvasMarkTool.allCases {
            XCTAssertTrue(
                script.contains("\"\(tool.token)\""),
                "the page never branches on \(tool.token), so holding it would do nothing")
        }
    }

    func testTheDefaultIsReadingRatherThanDrawing() {
        XCTAssertFalse(
            CanvasMarkTool.select.draws,
            "a canvas nobody has touched must behave exactly as it did before this slice")
        XCTAssertTrue(CanvasHTML.annotationScript().contains("\"select\""))
    }

    func testEveryDrawingToolIsDistinguishableInThePicker() {
        let symbols = Set(CanvasMarkTool.allCases.map(\.symbol))
        XCTAssertEqual(
            symbols.count, CanvasMarkTool.allCases.count,
            "two tools sharing an icon is a picker you cannot read")
        XCTAssertTrue(CanvasMarkTool.allCases.allSatisfy { !$0.help.isEmpty })
    }

    func testSettingTheToolIsOneStatementAndQuotesItsArgument() {
        // It is evaluated in the page, so the token has to arrive as a JS string rather than
        // a bare identifier — the difference between setting a tool and a ReferenceError.
        XCTAssertEqual(
            CanvasHTML.setMarkTool(.freehand), "window.__helmMarkTool = \"freehand\";")
    }
}
