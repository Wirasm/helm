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
/// `CanvasAnnotationScriptTests` and `CanvasEnclosureTests` mount no board at all — the fixture
/// is opt-in, see `mountBoard` — so every mark they assert on is a mark that must still happen.
/// Both suites pass unchanged, and that is what says this change is scoped to a declared
/// region rather than to marking as such.
///
/// **What is out of reach here, so it is not claimed.** JavaScriptCore has no layout engine and
/// no pointer-event model, so nothing below proves that a real board *receives* the gesture
/// helm let through — only that helm let it through. That half was read in quickdraw's source
/// (`CanvasSurface`'s header cites the lines) and is checkable in a live helm; it is not
/// something a Swift gate can reach.
final class CanvasSurfaceTests: XCTestCase {

    // MARK: The pointer

    /// A mark tool held over a declared surface takes nothing: no `preventDefault`, no stroke,
    /// no ink.
    ///
    /// **`preventDefault` is asserted on directly**, and it is the assertion that matters most
    /// even though it is the one that changes least. Cancelling the compatibility `mousedown`
    /// never stopped quickdraw — it listens on `pointerdown` and never cancels it — so what it
    /// actually cancelled was the browser's own defaults on a gesture the board was already
    /// handling. Leaving it in place would be helm quietly editing the behaviour of a surface
    /// it had just agreed was not its.
    func testAMarkToolTakesNothingInsideADeclaredSurface() throws {
        let page = try CanvasScriptRuntime()
        page.mountBoard()
        page.setTool(.freehand)

        let board = CanvasScriptRuntime.boardBox
        XCTAssertFalse(
            page.mouse("mousedown", board.x + 100, board.y + 100),
            "helm must leave the browser's defaults alone on a pointer the page owns")
        page.mouse("mousemove", board.x + 300, board.y + 150)
        page.mouse("mouseup", board.x + 400, board.y + 180)

        XCTAssertTrue(page.posted.isEmpty, "and it must post no mark for a gesture that is not its")
        XCTAssertFalse(page.hasMarkLayer, "and lay no ink over the board's own")

        // The control, and it is the half that fails if this yielded everywhere: the identical
        // gesture on ordinary prose still takes the pointer and still marks.
        XCTAssertTrue(
            page.mouse("mousedown", 100, 1390),
            "the same tool outside the surface must still take the pointer")
        page.mouse("mousemove", 200, 1420)
        page.mouse("mouseup", 300, 1440)
        XCTAssertEqual(page.lastPosted?["kind"] as? String, "enclosure")
        XCTAssertTrue(page.hasMarkLayer)
        XCTAssertTrue(page.drainExceptions().isEmpty)
    }

    /// The default tool — the one nobody chose — says nothing about a click on the board.
    ///
    /// This is the collision with a live cost. A drag on a board leaves `document.getSelection()`
    /// collapsed, the branch below posted `cleared`, and helm answers a dismissal by taking the
    /// operator's selection down and closing the notes drawer. Every stroke closed their notes.
    func testTheDefaultToolSaysNothingAboutAClickInsideADeclaredSurface() throws {
        let page = try CanvasScriptRuntime()
        page.mountBoard()
        page.setTool(.select)

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

    /// The yield is about where the gesture *is*, not a global off switch: a stroke begun on the
    /// page and released over the board is still helm's, and still completes.
    ///
    /// It has to be. A stroke's mark is decided at `mousedown` — that is where the tool takes the
    /// pointer — so abandoning it on release would leave ink on screen with no message behind it,
    /// which is the one state `committed` exists to prevent.
    func testAStrokeBegunOnThePageStillCompletesWhenItEndsOverTheBoard() throws {
        let page = try CanvasScriptRuntime()
        page.mountBoard()
        page.setTool(.freehand)

        let board = CanvasScriptRuntime.boardBox
        page.mouse("mousedown", 100, 1390)
        page.mouse("mousemove", 200, 900)
        page.mouse("mouseup", board.x + 200, board.y + 100)

        XCTAssertEqual(
            page.lastPosted?["kind"] as? String, "enclosure",
            "the gesture was helm's from the press; where the hand stopped does not unmake it")
        XCTAssertTrue(page.drainExceptions().isEmpty)
    }

    // MARK: What can be named

    /// **Nothing inside a declared surface is ever an anchor**, and this is the half of the rule
    /// with no visible symptom.
    ///
    /// A mounted board is one `<canvas>` with no per-shape nodes, so an enclosure over it can
    /// only report the container — anchored to an id naming the whole board, quoting whatever
    /// text its chrome happens to carry. The board's own records carry ids the agent can find
    /// again and reach it through the state latch (#110); an anchor here would be a worse answer
    /// wearing the same shape as a good one.
    func testNothingInsideADeclaredSurfaceIsEverNamed() throws {
        let page = try CanvasScriptRuntime()
        page.mountBoard()
        page.setTool(.freehand)

        // Begun outside the board — so the stroke is helm's — and drawn right around it.
        let board = CanvasScriptRuntime.boardBox
        page.loop(
            around: (
                x: board.x - 10, y: board.y - 10,
                width: board.width + 20, height: board.height + 20
            ))

        let message = try XCTUnwrap(page.lastPosted)
        XCTAssertEqual(message["kind"] as? String, "enclosure")
        let targets = (message["targets"] as? [[String: Any]]) ?? []
        XCTAssertEqual(
            targets.compactMap { $0["id"] as? String }, [],
            "the board's container and its toolbar are inside a surface and cannot be anchors")
        XCTAssertTrue(
            targets.isEmpty,
            "and neither may come back as a bare quote — `CanvasAnnotation.decode` refuses an "
                + "empty enclosure, which is the honest outcome for a loop drawn round a board")

        // The control, in the same shape: an identical loop round ordinary prose still names it.
        // Without this, "reports nothing" is satisfied by reporting nothing anywhere.
        page.loop(around: (x: 10, y: 1390, width: 330, height: 50))
        let outside = try XCTUnwrap(page.lastPosted)
        XCTAssertEqual(
            (outside["targets"] as? [[String: Any]])?.compactMap { $0["id"] as? String },
            ["item-a"])
        XCTAssertTrue(page.drainExceptions().isEmpty)
    }

    /// A tap inside a surface resolves to nothing, so it is refused rather than anchored to the
    /// board — the same rule reaching the other resolver, which is why the guard sits in
    /// `resolve` rather than at one call site.
    func testATapInsideADeclaredSurfaceResolvesToNothing() throws {
        let page = try CanvasScriptRuntime()
        page.mountBoard()
        page.setTool(.point)

        let board = CanvasScriptRuntime.boardBox
        page.mouse("mousedown", board.x + 100, board.y + 100)
        page.mouse("mouseup", board.x + 100, board.y + 100)

        XCTAssertTrue(
            page.posted.isEmpty,
            "the press yielded, so there is no gesture to resolve and nothing to say")

        // The control: a tap on the page still names what it hit.
        page.tap(at: (x: 100, y: 110))
        XCTAssertEqual(page.lastPosted?["kind"] as? String, "point")
        XCTAssertEqual(page.lastPosted?["id"] as? String, "intro")
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

    /// Four levels up from `Tests/HelmTests/Canvas/` — the same walk
    /// `SpoolWireConformanceTests` does, and for the same reason: this reads a file no compiler
    /// touches, from a unit test that has to find it itself.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Canvas/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }
}
