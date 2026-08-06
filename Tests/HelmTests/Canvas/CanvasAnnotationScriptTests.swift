import XCTest

@testable import Helm

/// The annotation script, **executed**.
///
/// Everything here drives `Sources/Helm/Resources/canvas-annotation.js` — the same bytes
/// `CanvasHTML.annotationScript()` hands WebKit — through `CanvasScriptRuntime`, and asserts on
/// what it did. That is the whole of #197: while the script was a Swift string literal the
/// suite carried 94 substring assertions and every one of them passed while #190, #196 and
/// #208 shipped. Two is luck. Three, all invisible to the same assertions, is the medium.
///
/// **What this cannot reach**, so it is not claimed: the content world the script is injected
/// into, its injection time, and everything else that is WebKit's rather than the script's.
/// #190 lived there and would still not be caught here. `GhosttySmokeTests` records the manual
/// pass; this is the half that no longer needs one.
final class CanvasAnnotationScriptTests: XCTestCase {

    // MARK: The script itself

    /// A syntax error used to be checked by counting braces. This is the real answer: the
    /// script parses, or `CanvasScriptRuntime.init` throws with the engine's own message.
    func testTheScriptParsesAndArmsThePage() throws {
        let page = try CanvasScriptRuntime()

        for gesture in ["mousedown", "mousemove", "mouseup", "mouseleave"] {
            XCTAssertEqual(
                page.listenerCount(on: "document", for: gesture), 1,
                "the page must listen for \(gesture) exactly once")
        }
        XCTAssertEqual(page.listenerCount(on: "window", for: "blur"), 1)
        XCTAssertTrue(page.hasGlobal("__helmWipeMark"), "Swift takes a posted mark down")
        XCTAssertTrue(page.hasGlobal("__helmAbandonMark"), "a tool change drops half-drawn work")
        XCTAssertTrue(page.drainExceptions().isEmpty)
    }

    /// **The canvas must render correctly without helm** (#33). A page that came to depend on
    /// an injected global would render in helm and be a blank page in `playwright-cli`, so the
    /// agent would validate a different artifact from the one it is shown.
    func testACanvasWithNoBridgeIsLeftCompletelyAlone() throws {
        let page = try CanvasScriptRuntime(bridge: false)

        for gesture in ["mousedown", "mousemove", "mouseup", "mouseleave"] {
            XCTAssertEqual(page.listenerCount(on: "document", for: gesture), 0)
        }
        XCTAssertEqual(page.listenerCount(on: "window", for: "blur"), 0)
        XCTAssertFalse(page.hasGlobal("__helmWipeMark"))
        XCTAssertFalse(page.hasGlobal("__helmMarkTool"), "not even the default tool is set")
        XCTAssertTrue(
            page.drainExceptions().isEmpty, "and it returns rather than throwing on the way out")
    }

    /// The one thing the move to a `.js` file made able to drift silently: the script spells
    /// the handler name and the tool global out, where it used to interpolate the Swift
    /// constants. Both are compile-time constants, so this is the whole of that risk.
    func testTheScriptStillNamesTheSwiftConstantsItUsedToInterpolate() {
        let script = CanvasHTML.annotationScript()

        XCTAssertFalse(script.isEmpty, "the resource must ship in the bundle")
        XCTAssertTrue(
            script.contains("window.webkit.messageHandlers.\(CanvasBridgePolicy.handlerName)"),
            "the page reads a handler Swift never registered, and marking is silently dead")
        XCTAssertTrue(
            script.contains("window.\(CanvasHTML.markToolGlobal)"),
            "the picker sets a global the page never reads, and every tool is a no-op")
        XCTAssertFalse(
            script.contains("\\("), "an unexpanded Swift interpolation reaching the page")
    }

    // MARK: The tool decides the mark

    /// #112's own contract, and the first cut got it wrong by inferring the mark from the
    /// gesture's shape. One identical drag, three tools, three different marks — which a
    /// substring check cannot express at all.
    func testOneGestureMeansWhateverToolIsHeld() throws {
        var marks: [String] = []
        for tool in [CanvasMarkTool.arrow, .freehand] {
            let page = try CanvasScriptRuntime()
            page.setTool(tool)
            page.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))
            marks.append(try XCTUnwrap(page.lastPosted?["mark"] as? String))
        }

        let tapping = try CanvasScriptRuntime()
        tapping.setTool(.point)
        tapping.tap(at: (x: 100, y: 110))
        marks.append(try XCTUnwrap(tapping.lastPosted?["mark"] as? String))

        XCTAssertEqual(marks, ["relation", "enclosure", "point"])
    }

    /// The fall-through used to be freehand, so a garbage token silently drew a circle.
    func testAToolHelmDoesNotKnowDoesNothingAtAll() throws {
        let page = try CanvasScriptRuntime()
        page.evaluateFromSwift("window.\(CanvasHTML.markToolGlobal) = \"sketch\";")

        page.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))

        XCTAssertTrue(page.posted.isEmpty, "an unknown tool must not post a mark")
        XCTAssertTrue(page.drainExceptions().isEmpty)
    }

    /// A tool is a sticky selection, unlike the modifier it replaced: a right-click for the
    /// page's own context menu would otherwise start a stroke the menu's tracking loop eats.
    func testOnlyThePrimaryButtonStartsAStroke() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.freehand)

        XCTAssertFalse(
            page.mouse("mousedown", 100, 40, button: 2),
            "the default must survive, or the page's own context menu never opens")
        page.mouse("mousemove", 200, 200)
        page.mouse("mouseup", 200, 200)

        XCTAssertTrue(page.posted.isEmpty)
        XCTAssertFalse(page.hasMarkLayer, "and nothing was drawn on the way")

        XCTAssertTrue(
            page.mouse("mousedown", 100, 40),
            "while a primary press does take the pointer, or the drag selects text instead")
    }

    // MARK: Text selection, which predates every tool

    func testSelectReportsWhatWasSelectedAndWhereItIs() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.select)
        page.select(id: "intro", text: "Why this exists")

        page.mouse("mouseup", 100, 110)

        let message = try XCTUnwrap(page.lastPosted)
        XCTAssertEqual(message["id"] as? String, "intro")
        XCTAssertEqual(message["text"] as? String, "Why this exists")
        XCTAssertNil(message["mark"], "a selection is the default kind and carries no marker")
    }

    /// #165: a click that selected nothing has to be *reported*, not swallowed. It is the
    /// canvas's click-elsewhere-to-dismiss, and the only one of the comment field's exits that
    /// does not go through the keyboard.
    func testAClickThatSelectedNothingPostsADismissal() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.select)

        page.mouse("mouseup", 100, 110)

        XCTAssertEqual(page.lastPosted?["cleared"] as? Bool, true)
    }

    // MARK: Coordinate spaces (#196)

    /// The stroke is in PAGE coordinates so the ink scrolls with its subject. The rect that
    /// travels to Swift is not: it places the comment field on screen. #196 moved both and the
    /// field landed off screen; every substring assertion passed.
    ///
    /// Every tool, because each posts its own `rect:` and #196 was one call site out of three.
    func testTheStrokeIsPageRelativeAndEveryPostedRectIsNot() throws {
        let scroll = 500.0
        // Each gesture, and the topmost PAGE coordinate its bounding box should have.
        let gestures: [(CanvasMarkTool, (CanvasScriptRuntime) -> Void, Double)] = [
            (.point, { $0.tap(at: (x: 100, y: 1410)) }, 1410),
            (.arrow, { $0.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410)) }, 40),
            (.freehand, { $0.loop(around: (x: 10, y: 1390, width: 320, height: 50)) }, 1390),
        ]

        for (tool, gesture, pageTop) in gestures {
            let page = try CanvasScriptRuntime()
            page.scroll(x: 0, y: scroll)
            page.setTool(tool)

            gesture(page)

            let rect = try XCTUnwrap(page.lastPosted?["rect"] as? [String: Any])
            XCTAssertEqual(
                rect["y"] as? Double, pageTop - scroll,
                "\(tool.token) places the comment field in the viewport, not on the page")
        }

        // …and the ink itself stays where the hand drew it, which is the other half of #196.
        let drawing = try CanvasScriptRuntime()
        drawing.scroll(x: 0, y: scroll)
        drawing.setTool(.freehand)
        drawing.loop(around: (x: 10, y: 1390, width: 320, height: 50))
        XCTAssertTrue(
            try XCTUnwrap(drawing.inkPaths.first).d.contains("1390"),
            "the ink is drawn at the page coordinate, so it scrolls with its subject")
    }

    /// The other half of the same conversion: element rects come back viewport-relative, so
    /// what a loop covers must be scroll-invariant.
    func testALoopCoversTheSameThingsWhateverTheScrollPositionIs() throws {
        func targetIDs(scrolledTo y: Double) throws -> [String] {
            let page = try CanvasScriptRuntime()
            page.scroll(x: 0, y: y)
            page.setTool(.freehand)
            page.loop(around: (x: 10, y: 1390, width: 320, height: 50))
            let targets = try XCTUnwrap(page.lastPosted?["targets"] as? [Any])
            return targets.compactMap { ($0 as? [String: Any])?["id"] as? String }
        }

        XCTAssertEqual(try targetIDs(scrolledTo: 0), ["item-a"])
        XCTAssertEqual(try targetIDs(scrolledTo: 900), ["item-a"])
    }

    // MARK: The ink

    /// Two ways a completed mark used to vanish before the operator had looked at it: the
    /// comment field autofocusing (which blurs the webview) and switching tools. Both called
    /// the same unconditional wipe as an abandoned drag.
    ///
    /// Every tool that posts a mark, because each commits at its own `return` — a fourth kind
    /// added later that forgot to would be the same bug back.
    func testAPostedMarkOutlivesEverythingExceptSwiftTakingItDown() throws {
        for tool in CanvasMarkTool.allCases where tool.draws {
            let page = try CanvasScriptRuntime()
            page.setTool(tool)
            switch tool {
            case .point: page.tap(at: (x: 100, y: 110))
            case .arrow: page.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))
            default: page.loop(around: (x: 10, y: 1390, width: 320, height: 50))
            }
            XCTAssertFalse(page.posted.isEmpty, "\(tool.token) posted nothing to comment on")
            XCTAssertTrue(page.hasMarkLayer, "\(tool.token): releasing must not erase the mark")

            page.blurWindow()
            XCTAssertTrue(
                page.hasMarkLayer, "\(tool.token): the field taking the keyboard is not an abandon")

            page.evaluateFromSwift(CanvasHTML.setMarkTool(.select))
            XCTAssertTrue(page.hasMarkLayer, "\(tool.token): nor is changing tools")

            page.evaluateFromSwift(CanvasHTML.clearMarkScript())
            XCTAssertFalse(
                page.hasMarkLayer, "\(tool.token): only Swift closing the field takes it down")
        }
    }

    /// The case the guard above must not break: a drag released outside the document never
    /// fires mouseup, and its ink would otherwise sit at max z-index until the next stroke.
    /// Both routes out of the document, because both are wired to `abandon`.
    func testAnInFlightGestureIsStillDiscardedWhenItLeavesTheDocument() throws {
        for leave in ["blur", "mouseleave"] {
            let page = try CanvasScriptRuntime()
            page.setTool(.freehand)
            page.mouse("mousedown", 20, 1400)
            page.mouse("mousemove", 300, 1420)
            XCTAssertTrue(page.hasMarkLayer, "the stroke is being drawn")

            if leave == "blur" { page.blurWindow() } else { page.mouseLeaveDocument() }

            XCTAssertFalse(page.hasMarkLayer, "\(leave) must take an in-flight stroke down")
            XCTAssertTrue(page.posted.isEmpty, "and nothing was ever posted about it")
        }
    }

    /// A tap draws nothing on its way, so it is the one gesture that would otherwise leave no
    /// visible subject for the comment field.
    func testATapLeavesARing() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.point)

        page.tap(at: (x: 100, y: 110))

        XCTAssertEqual(page.ringCount, 1)
    }

    /// An unresolvable `marker-end` url() is IGNORED rather than erroring, so a missing
    /// `<marker>` is a silently bare line — the one cue that tells arrow from freehand
    /// mid-draw. Referenced *and* defined, checked together.
    func testTheArrowheadTheInkPointsAtIsActuallyDefined() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.arrow)

        page.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))

        XCTAssertEqual(try XCTUnwrap(page.inkPaths.first).markerEnd, "url(#helm-mark-head)")
        XCTAssertTrue(
            page.markLayerIDs.contains("helm-mark-head"), "referenced but never defined")
    }

    func testTheInkIsInertSoThePageCanNeverComeToNeedIt() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.freehand)
        page.loop(around: (x: 10, y: 1390, width: 320, height: 50))

        XCTAssertTrue(page.markLayerStyle.contains("pointer-events:none"))
        XCTAssertTrue(
            page.markLayerStyle.contains("position:absolute"),
            "fixed positioning would leave the ink over whatever scrolled underneath")
    }

    /// The mark layer sits at the top of the stacking order over the whole document, so a hit
    /// test run without hiding it resolves every gesture to helm's own ink.
    func testTheHitTestSeesThePageAndNotThePaperOverIt() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.arrow)

        // The paper exists by mouseup — it was created on the first mousemove.
        page.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))

        let to = try XCTUnwrap(page.lastPosted?["to"] as? [String: Any])
        XCTAssertEqual(to["id"] as? String, "item-a")
    }

    /// helm's chrome is marked as such so an agent reading the DOM can tell it from what it
    /// authored — and so a loop can never report it as something the operator marked.
    ///
    /// **The chrome is laid out and given text here on purpose.** As shipped, the arrowhead
    /// `<marker>` is excluded twice over before `closest("[data-helm-mark]")` is consulted:
    /// once for having no size, once for having no text. Deleting the guard therefore changes
    /// nothing, and a test written against the DOM as it stands passes either way — measured,
    /// by deleting it. So this constructs the state the guard is actually for, which is any
    /// chrome that is visible and readable, such as a labelled mark.
    func testHelmsOwnChromeIsNeverSomethingTheOperatorMarked() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.freehand)
        page.mouse("mousedown", 10, 1390)
        page.mouse("mousemove", 330, 1390)
        XCTAssertTrue(
            page.layOut(id: "helm-mark-head", x: 100, y: 1400, width: 20, height: 20),
            "the arrowhead def has to exist by now, or this test proves nothing")
        XCTAssertTrue(page.giveText(id: "helm-mark-head", text: "helm's own ink"))
        page.mouse("mousemove", 330, 1440)
        page.mouse("mousemove", 10, 1440)
        page.mouse("mouseup", 10, 1396)

        let targets = try XCTUnwrap(page.lastPosted?["targets"] as? [Any])
        let ids = targets.compactMap { ($0 as? [String: Any])?["id"] as? String }
        XCTAssertEqual(ids, ["item-a"], "helm's own ink is inside the loop and must be excluded")
    }

    // MARK: The seam

    /// **What makes the two halves of the bridge agree, now that they are two files.** The
    /// running script produces the payload and the real `CanvasAnnotation.decode` consumes it —
    /// nothing in between is retyped by hand. It is a gate rather than a contract: JavaScript
    /// cannot compile against a Swift type, which `AGENTS.md` names as the standard this
    /// cannot meet, so the standard it does meet is stated instead of implied.
    func testEveryMarkThePagePostsDecodesThroughTheRealDecoder() throws {
        let point = try CanvasScriptRuntime()
        point.setTool(.point)
        point.tap(at: (x: 100, y: 110))
        XCTAssertEqual(
            try decode(point.lastPosted),
            .point(.element(id: "intro", text: "Why this exists")))

        let arrow = try CanvasScriptRuntime()
        arrow.setTool(.arrow)
        arrow.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))
        XCTAssertEqual(
            try decode(arrow.lastPosted),
            .relation(
                from: .element(id: "title", text: "The Plan"),
                to: .element(id: "item-a", text: "Item A")))

        let loop = try CanvasScriptRuntime()
        loop.setTool(.freehand)
        loop.loop(around: (x: 10, y: 1390, width: 320, height: 50))
        XCTAssertEqual(
            try decode(loop.lastPosted),
            .enclosure(covering: [.element(id: "item-a", text: "Item A")]))

        let selection = try CanvasScriptRuntime()
        selection.setTool(.select)
        selection.select(id: "intro", text: "Why this exists")
        selection.mouse("mouseup", 100, 110)
        XCTAssertEqual(
            try decode(selection.lastPosted),
            .selection(.element(id: "intro", text: "Why this exists")))
    }

    /// **The gate, not the decoder — #216.** `CanvasPageSelection.init?` is what
    /// `WKScriptMessage.body` actually meets first: `CanvasFileViews.swift`'s
    /// `userContentController(_:didReceive:)` drops whatever it refuses before
    /// `CanvasAnnotation.decode` is ever reached. The test above proves the decoder
    /// understands a mark; it says nothing about whether the mark gets there; #216 shipped
    /// with every decoder test green because the gate one layer up required a top-level
    /// `text` an enclosure and a relation never carry. Feeding `lastPosted` — the real
    /// script's output, not a hand-typed literal — through the real gate is what would have
    /// caught it: a JS key rename or a dropped `mark` fails here even though `decode` never
    /// sees it.
    func testEveryMarkThePagePostsIsAdmittedByTheRealGate() throws {
        let point = try CanvasScriptRuntime()
        point.setTool(.point)
        point.tap(at: (x: 100, y: 110))
        guard case .selected = try XCTUnwrap(CanvasPageSelection(try XCTUnwrap(point.lastPosted)))
        else {
            return XCTFail("a point must be admitted as a selection")
        }

        let arrow = try CanvasScriptRuntime()
        arrow.setTool(.arrow)
        arrow.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))
        guard case .selected = try XCTUnwrap(CanvasPageSelection(try XCTUnwrap(arrow.lastPosted)))
        else {
            return XCTFail(
                "a relation must be admitted as a selection — it carries no top-level text")
        }

        let loop = try CanvasScriptRuntime()
        loop.setTool(.freehand)
        loop.loop(around: (x: 10, y: 1390, width: 320, height: 50))
        guard case .selected = try XCTUnwrap(CanvasPageSelection(try XCTUnwrap(loop.lastPosted)))
        else {
            return XCTFail(
                "an enclosure must be admitted as a selection — it carries no top-level text")
        }
    }

    /// The dismissal is the one message that deliberately decodes to nothing — it closes the
    /// comment field rather than writing a note.
    func testADismissalIsRefusedByTheDecoderRatherThanBecomingANote() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.select)
        page.mouse("mouseup", 100, 110)

        XCTAssertNil(
            CanvasAnnotation.decode(try XCTUnwrap(page.lastPosted), comment: "a comment"))
    }

    private func decode(_ body: [String: Any]?) throws -> CanvasAnnotation.Mark {
        let annotation = try XCTUnwrap(
            CanvasAnnotation.decode(try XCTUnwrap(body), comment: "a comment"),
            "the page posted a payload the real decoder refuses")
        return annotation.mark
    }
}
