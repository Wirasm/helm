import XCTest

@testable import Helm

/// **`data-helm-surface`, executed** — helm's mark layer meeting a page that owns its own
/// pointer (#111).
///
/// Every case here drives the shipped `Sources/Helm/Resources/canvas-annotation.js` through
/// `CanvasScriptRuntime`, on `CanvasAnnotationScriptTests`' reasoning: while that script was a
/// Swift string literal three consecutive PRs shipped a defect every substring assertion
/// passed, and a rule about what a gesture *does* cannot be checked by looking at the source
/// that implements it.
///
/// **Each test carries its own control in the same method**, because the failure mode of a
/// yield is yielding too much and a test that only proves helm marks less is satisfied by helm
/// marking nothing. The wider control is the rest of the canvas suite:
/// `CanvasAnnotationScriptTests` mounts no board at all — the fixture is opt-in, see
/// `mountBoard` — so every mark it asserts on is a mark that must still happen.
///
/// **What is out of reach here, so it is not claimed.** JavaScriptCore has no layout engine and
/// no pointer-event model, so nothing below proves that a real board *receives* the gesture
/// helm let through — only that helm let it through. That half was read in quickdraw's source
/// (`CanvasSurface`'s header cites the lines) and is checkable in a live helm; it is not
/// something a Swift gate can reach.
final class CanvasSurfaceTests: XCTestCase {

    // MARK: The pointer

    /// The **text** tool says nothing about a click on the board.
    ///
    /// This is the collision with a live cost. A drag on a board leaves `document.getSelection()`
    /// collapsed, the branch below posted `cleared`, and helm answers a dismissal by taking the
    /// operator's selection down and closing the notes drawer. Every stroke closed their notes.
    ///
    /// **This test held `.select` — the default — and #302 is why it now holds `.text`.** That
    /// change split `.select` into an inert `.read` and a `.text` tool, and made `.read` the
    /// default. Left as it was, this method would have gone on passing while measuring nothing:
    /// under `.read` the page posts nothing *anywhere*, so "the board posted nothing" would be
    /// satisfied by helm having stopped marking altogether — the control that only proves you
    /// select less. `.text` is the tool that can still reach `bridge.postMessage` on this path,
    /// so it is the only one whose silence over a board is evidence the yield is doing anything.
    /// Its own control, below, is the same gesture on ordinary prose.
    func testTheTextToolSaysNothingAboutAClickInsideADeclaredSurface() throws {
        let page = try CanvasScriptRuntime()
        page.mountBoard()
        page.setTool(.text)

        let board = CanvasScriptRuntime.boardBox
        page.mouse("mousedown", board.x + 100, board.y + 100)
        page.mouse("mouseup", board.x + 400, board.y + 180)

        XCTAssertTrue(
            page.posted.isEmpty,
            "a `cleared` here dismisses the operator's selection and closes their notes drawer")

        // The control: click-elsewhere-to-dismiss (#165) is not what this removes, and a
        // yield that swallowed it would be a comment field nothing can close.
        page.mouse("mouseup", 100, 1600)
        XCTAssertEqual(
            page.lastPosted?["kind"] as? String, "cleared",
            "a click on the page itself must still dismiss")
        XCTAssertTrue(page.drainExceptions().isEmpty)
    }

    // MARK: The seam

    /// **Three copies of one string, and a JavaScript file cannot compile against a Swift
    /// constant** — so the gate is a test that reads every half (`AGENTS.md`).
    ///
    /// The third copy is the one that makes this a contract rather than a constant with a single
    /// reader: `.claude/skills/helm-board/board.html` is the artifact template that *declares*
    /// the surface. A template that stopped writing the attribute would be a board whose every
    /// stroke closed the operator's notes drawer, with nothing on helm's side changed and every
    /// other test in this repository green.
    func testEveryHalfOfTheSurfaceSeamStillSpellsItTheSameWay() throws {
        let script = CanvasHTML.annotationScript()
        XCTAssertFalse(script.isEmpty, "the resource must ship in the bundle")
        XCTAssertTrue(
            script.contains(CanvasSurface.selector),
            "the script must ask for `\(CanvasSurface.selector)`, or every page owns nothing "
                + "and a board's every stroke closes the operator's notes")
        XCTAssertFalse(
            script.contains("\\("), "an unexpanded Swift interpolation reaching the page")

        let template =
            repositoryRoot
            .appendingPathComponent(".claude/skills/helm-board/board.html")
        let markup = try String(contentsOf: template, encoding: .utf8)
        // **The whole opening tag, not the attribute name.** `CanvasAnchorTests
        // .testTheScriptAndTheGeneratedPageStillAgreeOnHelmsWrapper` already asserts on
        // `<article id="content" data-helm-frame>` for exactly this reason, and the first cut of
        // this test used the weaker form and was **satisfied by the template's own comment**:
        // that file explains the contract in prose above the element, so deleting the real
        // declaration off the `<main>` left one occurrence behind and this stayed green.
        // Measured on a copy of the file — two occurrences became one and it still passed. A
        // check bound to the documentation rather than to the declaration is not a check.
        XCTAssertTrue(
            markup.contains("<main id=\"board\" \(CanvasSurface.attribute)>"),
            "the board template must declare `\(CanvasSurface.attribute)` on the element "
                + "quickdraw mounts into, or helm and the board fight over every gesture")
    }

    /// Four levels up from `Tests/HelmTests/Canvas/`: this reads a file no compiler touches,
    /// from a unit test that has to find it itself.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Canvas/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }
}
