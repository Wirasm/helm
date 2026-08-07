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
        XCTAssertTrue(
            script.contains("window.\(CanvasHTML.markTintGlobal)"),
            "Swift pushes a colour the page never reads, and a text mark paints nothing (#308)")
        XCTAssertTrue(
            script.contains("\"\(CanvasHTML.markHighlightName)\""),
            "the page registers its highlight under one name and Swift's tests look for another")
        XCTAssertFalse(
            script.contains("\\("), "an unexpanded Swift interpolation reaching the page")
        XCTAssertFalse(
            script.lowercased().contains("background-color:#"),
            "a literal colour in the page is the defect the palette exists to remove — the "
                + "tint is `Palette.helm.selection`, resolved by `CanvasHTML.markTint`")
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
            marks.append(try XCTUnwrap(page.lastPosted?["kind"] as? String))
        }

        let tapping = try CanvasScriptRuntime()
        tapping.setTool(.point)
        tapping.tap(at: (x: 100, y: 110))
        marks.append(try XCTUnwrap(tapping.lastPosted?["kind"] as? String))

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

    // MARK: The text tool, whose behaviour predates every tool

    /// **This is `.select`'s behaviour, unchanged, under the name it was split into** (#302).
    /// The tool is now picked up rather than always armed, and nothing else about it moved:
    /// same message, same keys, same rect. That is what makes it a split rather than a
    /// redesign, and it is the reason these two methods are worth reading as a pair with
    /// `CanvasMarkToolTests.testACanvasNobodyHasTouchedPostsNothingAtAll` — same gestures,
    /// opposite verdicts, and the only difference between them is which tool is held.
    func testTheTextToolReportsWhatWasSelectedAndWhereItIs() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
        page.select(id: "intro", text: "Why this exists")

        page.mouse("mouseup", 100, 110)

        let message = try XCTUnwrap(page.lastPosted)
        XCTAssertEqual(message["id"] as? String, "intro")
        XCTAssertEqual(message["text"] as? String, "Why this exists")
        XCTAssertEqual(
            message["kind"] as? String, "selection",
            "a selection used to be the DEFAULT kind and carry no marker at all — which is "
                + "what made the gate infer the shape, and #216 is the bill (#109)")
    }

    /// #165: a click that selected nothing has to be *reported*, not swallowed. It is the
    /// canvas's click-elsewhere-to-dismiss, and the only one of the comment field's exits that
    /// does not go through the keyboard.
    ///
    /// **`cleared` survives #302, and this is where it earns it.** That change stopped the
    /// *reading* tool posting one — which was the message arriving when nobody had marked
    /// anything — and left this one exactly as it was: a `.text` click away from the passage
    /// being commented on. Deleting `cleared` with the default would have taken the comment
    /// field's only mouse exit with it.
    func testAClickThatSelectedNothingPostsADismissal() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)

        page.mouse("mouseup", 100, 110)

        XCTAssertEqual(page.lastPosted?["kind"] as? String, "cleared")
    }

    // MARK: The text mark stays painted (#308)

    /// **The whole of #308, as one journey.** Three tools kept their mark and one did not:
    /// freehand and arrow leave ink, point leaves a ring, and a text mark was the browser's own
    /// selection — which greys the instant the comment field takes the keyboard, so the operator
    /// was asked to comment on a passage that had stopped looking marked.
    ///
    /// Every step here is a real event the script listens for, in the order a person produces
    /// them: mark, the field takes focus (`blur`), the operator leaves for a terminal pane and
    /// comes back (`mouseleave`, then nothing), and finally Swift closes the field.
    func testATextMarkStaysPaintedUntilTheCommentIsPostedOrAbandoned() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
        page.select(id: "intro", text: "Why this exists")

        page.mouse("mouseup", 100, 110)

        XCTAssertEqual(
            page.textMark?.text, "Why this exists",
            "releasing must leave the passage painted — that IS the mark")

        // The comment field appearing takes the keyboard, which blurs the page and drops the
        // native selection. Both, because either one alone used to be enough to lose the mark.
        page.collapseSelection()
        page.blurWindow()
        XCTAssertEqual(
            page.textMark?.text, "Why this exists",
            "the field taking the keyboard is the moment this exists to survive")

        // Off to a terminal pane and back. `dismissSelection`'s header: reading what the agent
        // said about a passage and coming back to comment on it is the ordinary path.
        page.mouseLeaveDocument()
        XCTAssertEqual(
            page.textMark?.text, "Why this exists",
            "a selection outlives a trip to another pane, so its mark has to as well")

        // Posted, or abandoned by the ✕ or Escape — one path, because all three close the field.
        page.evaluateFromSwift(CanvasHTML.clearMarkScript())
        XCTAssertNil(page.textMark, "only Swift closing the field takes it down")
        XCTAssertEqual(page.highlightNames, [], "and it leaves nothing of helm's in the registry")
    }

    /// **The clone is the feature, not a tidiness.** `getRangeAt(0)` hands back a range the
    /// Selection still owns, and the native selection goes away the moment the comment field
    /// takes the keyboard — the exact moment the mark has to survive. The stub models the two
    /// as different objects for this assertion alone.
    func testTheTextMarkIsTheOperatorsRangeAndNotTheBrowsersLiveSelection() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
        page.select(id: "detail", text: "How it works")

        page.mouse("mouseup", 100, 190)

        let mark = try XCTUnwrap(page.textMark)
        XCTAssertTrue(mark.cloned, "registering the Selection's own range ties helm's mark to it")
        XCTAssertEqual(mark.id, "detail", "and it still covers what was marked")
    }

    /// The mark is helm's chrome, so it spends a palette token — and the page holds no colour of
    /// its own to spend instead. Asserted against `Palette.helm.selection` rather than a hex, so
    /// the token moving moves this with it and a literal creeping in fails here.
    func testTheTextMarkPaintsWithThePaletteColourSwiftPushed() throws {
        for theme in [CanvasTheme.light, .dark] {
            let page = try CanvasScriptRuntime()
            // The string Swift actually pushes, run for real — not the harness's shortcut, so
            // this covers `setMarkTool` and the page's reading of it in one.
            page.evaluateFromSwift(CanvasHTML.setMarkTool(.text, theme: theme))
            page.select(id: "intro", text: "Why this exists")

            page.mouse("mouseup", 100, 110)

            let style = page.adoptedStyle
            XCTAssertTrue(
                style.contains("::highlight(\(CanvasHTML.markHighlightName))"),
                "a registered highlight with no rule paints nothing — \(style)")
            XCTAssertTrue(
                style.contains(Palette.helm.selection.value(in: theme.appearance).hex),
                "\(theme): the tint must be the palette's, not a colour the page chose — \(style)")
            XCTAssertFalse(
                style.contains(
                    Palette.helm.selection.value(in: theme.appearance == .dark ? .light : .dark).hex
                ),
                "\(theme): painted in the other appearance's value")
        }
    }

    /// `document.adoptedStyleSheets` belongs to the document, and an artifact's own script may
    /// replace it wholesale. A registered highlight whose rule went with it paints nothing,
    /// which is indistinguishable from no mark at all — so the rule is re-checked per paint.
    func testTheHighlightRuleComesBackWhenTheArtifactReplacesTheDocumentsAdoptedStyles() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
        page.select(id: "intro", text: "Why this exists")
        page.mouse("mouseup", 100, 110)
        XCTAssertEqual(page.adoptedSheetCount, 1)

        page.dropAdoptedStyles()
        page.select(id: "detail", text: "How it works")
        page.mouse("mouseup", 100, 190)

        XCTAssertTrue(
            page.adoptedStyle.contains("::highlight(\(CanvasHTML.markHighlightName))"),
            "the rule has to come back, or the second mark is registered and invisible")
        XCTAssertEqual(page.adoptedSheetCount, 1, "and helm adopts one sheet, not one per mark")
    }

    /// A click away from the passage takes the mark down **here**, rather than waiting to be
    /// told. Swift answers a `cleared` by closing the field, which comes back as a wipe — but a
    /// render later, and in between the operator is looking at a highlight over the thing they
    /// just clicked away from. Exactly what `point` already does when it resolves no target.
    func testAClickThatSelectedNothingTakesTheTextMarkDownAtOnce() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
        page.select(id: "intro", text: "Why this exists")
        page.mouse("mouseup", 100, 110)
        XCTAssertNotNil(page.textMark)

        page.collapseSelection()
        page.mouse("mouseup", 100, 110)

        XCTAssertNil(page.textMark)
        XCTAssertEqual(page.lastPosted?["kind"] as? String, "cleared")
    }

    /// **One mark on screen, across a tool change — the case every existing test missed** by
    /// building a fresh page per tool and calling `setTool` exactly once.
    ///
    /// Both halves of the round trip, because only one of them was broken and the diagnosis
    /// depends on knowing which. A drawing tool wipes at `mousedown`, so `.text` → `.freehand`
    /// was always clean. `.text` is exempted from that wipe on purpose — cancelling `mousedown`
    /// is what would stop the operator selecting at all — so `.freehand` → `.text` had nothing
    /// clearing the ink, and the arrow stayed painted beside the new highlight with only one of
    /// them being what the comment field is about.
    ///
    /// **Latent before this slice and real after it**, which is why it belongs to #308 rather
    /// than to #112: `.text` painted nothing of its own, so the orphaned ink was the only thing
    /// on screen instead of one of two contradictory marks.
    func testANewMarkReplacesWhateverToolMadeTheLastOne() throws {
        let drawnFirst = try CanvasScriptRuntime()
        drawnFirst.setTool(.arrow)
        drawnFirst.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))
        XCTAssertTrue(drawnFirst.hasMarkLayer, "the arrow is the mark awaiting a comment")

        // Picking a tool up must NOT drop a committed mark — that is the contract
        // `testAPostedMarkOutlivesEverythingExceptSwiftTakingItDown` pins — so the ink is still
        // there when the text gesture starts, and clearing it is the text branch's job.
        drawnFirst.evaluateFromSwift(CanvasHTML.setMarkTool(.text, theme: .light))
        drawnFirst.select(id: "intro", text: "Why this exists")
        drawnFirst.mouse("mouseup", 100, 110)

        XCTAssertEqual(drawnFirst.textMark?.text, "Why this exists", "the new mark is painted")
        XCTAssertFalse(
            drawnFirst.hasMarkLayer,
            "and the arrow is gone — two marks on screen with one comment field between them "
                + "is a mark that lies about what is under discussion")

        let textFirst = try CanvasScriptRuntime()
        textFirst.setTool(.text)
        textFirst.select(id: "intro", text: "Why this exists")
        textFirst.mouse("mouseup", 100, 110)
        XCTAssertNotNil(textFirst.textMark)

        textFirst.evaluateFromSwift(CanvasHTML.setMarkTool(.freehand, theme: .light))
        textFirst.loop(around: (x: 10, y: 1390, width: 320, height: 50))

        XCTAssertTrue(textFirst.hasMarkLayer, "the loop is the mark now")
        XCTAssertNil(
            textFirst.textMark,
            "and the highlight went with the drawing tool's own mousedown wipe — this half was "
                + "already correct, and is here so a fix to the other half cannot break it")
    }

    /// **A control, and named as one.** The three tools built for #112 already kept their mark
    /// and none of them goes near the highlight registry; a change that started painting text
    /// highlights for a loop or a tap would be overshoot, and this is what fails on it. It
    /// passes with the whole of #308 removed, which is the point of a control.
    func testTheThreeDrawingToolsMarkTheirOwnWayAndRegisterNoTextHighlight() throws {
        for tool in CanvasMarkTool.allCases where tool.draws {
            let page = try CanvasScriptRuntime()
            page.setTool(tool)
            switch tool {
            case .point: page.tap(at: (x: 100, y: 110))
            case .arrow: page.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))
            default: page.loop(around: (x: 10, y: 1390, width: 320, height: 50))
            }

            XCTAssertTrue(page.hasMarkLayer, "\(tool.token) still marks the way it always did")
            XCTAssertEqual(
                page.highlightNames, [], "\(tool.token) has no text range and must paint none")
            XCTAssertEqual(page.adoptedSheetCount, 0, "and adopts no stylesheet either")
        }
    }

    /// **`data-helm-surface` still wins, and it wins before the paint** (#111/#300). Inside a
    /// declared surface helm does nothing at all — no stroke, no `cleared`, and now no highlight:
    /// a board is one `<canvas>` and a highlight over it would mean nothing.
    ///
    /// It is the `.text` branch's own early return that does this, which is why it is asserted
    /// rather than assumed — the paint sits below that return, and a paint added above it would
    /// be a highlight on a board with no message to go with it.
    func testATextGestureInsideAPageOwnedSurfacePaintsNothing() throws {
        let page = try CanvasScriptRuntime()
        page.mountBoard()
        page.setTool(.text)
        page.select(id: "board-tools", text: "Select Draw Arrow")

        let board = CanvasScriptRuntime.boardBox
        page.mouse("mouseup", board.x + 40, board.y + 40)

        XCTAssertTrue(page.posted.isEmpty, "silence, exactly as before")
        XCTAssertEqual(page.highlightNames, [], "and nothing painted over the board")
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
    ///
    /// **`.text` is that fourth kind, and it is here now** (#308). It was the tool this loop
    /// could not include, because the only mark it left was the browser's own selection and
    /// nothing here could see it; `where tool.draws` read as a description of the enum and was
    /// really the omission. Exhaustive over every tool but `.read` — which marks nothing by
    /// design — so a fifth tool has to state which kind of mark it leaves rather than being
    /// quietly skipped.
    func testAPostedMarkOutlivesEverythingExceptSwiftTakingItDown() throws {
        for tool in CanvasMarkTool.allCases where tool != .read {
            let page = try CanvasScriptRuntime()
            page.setTool(tool)
            switch tool {
            case .read: continue
            case .text:
                page.select(id: "intro", text: "Why this exists")
                page.mouse("mouseup", 100, 110)
            case .point: page.tap(at: (x: 100, y: 110))
            case .arrow: page.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))
            case .freehand: page.loop(around: (x: 10, y: 1390, width: 320, height: 50))
            }
            // What "the mark is up" means differs by tool and the difference is the point: the
            // drawn three leave ink on the paper, `.text` leaves a highlight over the passage.
            // One question, asked of whichever answer that tool gives.
            func markIsUp() -> Bool { tool == .text ? page.textMark != nil : page.hasMarkLayer }

            XCTAssertFalse(page.posted.isEmpty, "\(tool.token) posted nothing to comment on")
            XCTAssertTrue(markIsUp(), "\(tool.token): releasing must not erase the mark")

            page.blurWindow()
            XCTAssertTrue(
                markIsUp(), "\(tool.token): the field taking the keyboard is not an abandon")

            page.evaluateFromSwift(CanvasHTML.setMarkTool(.read, theme: .light))
            XCTAssertTrue(markIsUp(), "\(tool.token): nor is changing tools")

            page.evaluateFromSwift(CanvasHTML.clearMarkScript())
            XCTAssertFalse(
                markIsUp(), "\(tool.token): only Swift closing the field takes it down")
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
        selection.setTool(.text)
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
        guard
            case .selected = try CanvasPageSelection.decode(try XCTUnwrap(point.lastPosted)).get()
        else {
            return XCTFail("a point must be admitted as a selection")
        }

        let arrow = try CanvasScriptRuntime()
        arrow.setTool(.arrow)
        arrow.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))
        guard
            case .selected = try CanvasPageSelection.decode(try XCTUnwrap(arrow.lastPosted)).get()
        else {
            return XCTFail(
                "a relation must be admitted as a selection — it carries no top-level text")
        }

        let loop = try CanvasScriptRuntime()
        loop.setTool(.freehand)
        loop.loop(around: (x: 10, y: 1390, width: 320, height: 50))
        guard
            case .selected = try CanvasPageSelection.decode(try XCTUnwrap(loop.lastPosted)).get()
        else {
            return XCTFail(
                "an enclosure must be admitted as a selection — it carries no top-level text")
        }
    }

    /// **The seam the discriminator created, and the gate that holds it** (#109).
    ///
    /// `kind` is spelled in `canvas-annotation.js` and again in `CanvasPageSelection.Kind`, and
    /// JavaScript cannot compile against a Swift enum — so a kind renamed on one side and not
    /// the other is exactly the silent drift #216 was, with the refusal now happening in the
    /// gate instead of the inference. This runs the **real script** for every gesture and checks
    /// the kind it posts is one Swift declares, and that `cleared` — which no gesture below
    /// produces, because it is what a gesture produces when it finds *nothing* — is reachable
    /// too. `allCases` is what makes it every kind rather than a sample.
    func testTheScriptAndSwiftStillAgreeOnEveryMessageKind() throws {
        func kind(_ posted: [String: Any]?) throws -> CanvasPageSelection.Kind {
            let raw = try XCTUnwrap(
                (try XCTUnwrap(posted))["kind"] as? String,
                "the page posted a message with no `kind` at all — the gate refuses it and "
                    + "nothing the operator marks reaches helm")
            return try XCTUnwrap(
                CanvasPageSelection.Kind(rawValue: raw),
                "the script posts `kind: \(raw)`, which `CanvasPageSelection.Kind` does not "
                    + "declare — the gate refuses it by name and the mark is dropped")
        }

        let point = try CanvasScriptRuntime()
        point.setTool(.point)
        point.tap(at: (x: 100, y: 110))
        XCTAssertEqual(try kind(point.lastPosted), .point)

        let arrow = try CanvasScriptRuntime()
        arrow.setTool(.arrow)
        arrow.drag(from: (x: 100, y: 40), to: (x: 100, y: 1410))
        XCTAssertEqual(try kind(arrow.lastPosted), .relation)

        let loop = try CanvasScriptRuntime()
        loop.setTool(.freehand)
        loop.loop(around: (x: 10, y: 1390, width: 320, height: 50))
        XCTAssertEqual(try kind(loop.lastPosted), .enclosure)

        let highlight = try CanvasScriptRuntime()
        highlight.setTool(.text)
        highlight.select(id: "intro", text: "Why this exists")
        highlight.mouse("mouseup", 100, 110)
        XCTAssertEqual(try kind(highlight.lastPosted), .selection)

        let dismissal = try CanvasScriptRuntime()
        dismissal.setTool(.text)
        dismissal.mouse("mouseup", 100, 110)
        XCTAssertEqual(try kind(dismissal.lastPosted), .cleared)

        // **`.read` is the tool that produces no kind, and that is a fact about the seam too**
        // (#302). Every case above says "this gesture posts a kind Swift declares"; this one
        // says the inert tool posts nothing for Swift to declare a kind *for*. Without it the
        // set below reads as though five tools map onto five kinds, and the one that maps onto
        // none is the whole of the change.
        let reading = try CanvasScriptRuntime()
        reading.setTool(.read)
        reading.select(id: "intro", text: "Why this exists")
        reading.mouse("mouseup", 100, 110)
        XCTAssertTrue(
            reading.posted.isEmpty,
            "reading posts no message at all, so there is no `kind` for the gate to judge")

        XCTAssertEqual(
            Set(CanvasPageSelection.Kind.allCases.map(\.rawValue)),
            ["point", "relation", "enclosure", "selection", "cleared"],
            "a sixth kind was declared in Swift and this test was not extended to make the "
                + "script produce one — so nothing measures whether the page can post it")
    }

    /// The dismissal is the one message that deliberately decodes to nothing — it closes the
    /// comment field rather than writing a note.
    func testADismissalIsRefusedByTheDecoderRatherThanBecomingANote() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
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
