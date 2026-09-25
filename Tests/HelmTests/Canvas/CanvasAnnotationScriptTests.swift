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

        XCTAssertEqual(
            page.listenerCount(on: "document", for: "mouseup"), 1,
            "the page must listen for mouseup exactly once")
        XCTAssertTrue(page.hasGlobal("__helmWipeMark"), "Swift takes a posted mark down")
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
            script.contains(
                "window.webkit.messageHandlers.\(CanvasFileCoordinator.bridgeHandlerName)"),
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

    /// A tool token the page does not know marks nothing — it must not fall through to one
    /// that does.
    func testAToolHelmDoesNotKnowDoesNothingAtAll() throws {
        let page = try CanvasScriptRuntime()
        page.evaluateFromSwift("window.\(CanvasHTML.markToolGlobal) = \"sketch\";")

        page.select(id: "intro", text: "Why this exists")
        page.mouse("mouseup", 100, 110)

        XCTAssertTrue(page.posted.isEmpty, "an unknown tool must not post a mark")
        XCTAssertTrue(page.drainExceptions().isEmpty)
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

    /// **The whole of #308, as one journey.** A text mark was the browser's own selection —
    /// which greys the instant the comment field takes the keyboard, so the operator was asked
    /// to comment on a passage that had stopped looking marked.
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
    /// just clicked away from.
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

    /// **`data-helm-surface` still wins, and it wins before the paint** (#111/#300). Inside a
    /// declared surface helm does nothing at all — no `cleared`, and no highlight:
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

    // MARK: The mark's lifetime

    /// Two ways a completed mark used to vanish before the operator had looked at it: the
    /// comment field autofocusing (which blurs the webview) and switching tools.
    func testAPostedMarkOutlivesEverythingExceptSwiftTakingItDown() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
        page.select(id: "intro", text: "Why this exists")
        page.mouse("mouseup", 100, 110)

        XCTAssertFalse(page.posted.isEmpty, "the mark posted nothing to comment on")
        XCTAssertNotNil(page.textMark, "releasing must not erase the mark")

        page.blurWindow()
        XCTAssertNotNil(page.textMark, "the field taking the keyboard is not an abandon")

        page.evaluateFromSwift(CanvasHTML.setMarkTool(.read, theme: .light))
        XCTAssertNotNil(page.textMark, "nor is changing tools")

        page.evaluateFromSwift(CanvasHTML.clearMarkScript())
        XCTAssertNil(page.textMark, "only Swift closing the field takes it down")
    }

    // MARK: The seam

    /// **What makes the two halves of the bridge agree, now that they are two files.** The
    /// running script produces the payload and the real `CanvasAnnotation.decode` consumes it —
    /// nothing in between is retyped by hand. It is a gate rather than a contract: JavaScript
    /// cannot compile against a Swift type, which `AGENTS.md` names as the standard this
    /// cannot meet, so the standard it does meet is stated instead of implied.
    func testEveryMarkThePagePostsDecodesThroughTheRealDecoder() throws {
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
    /// `text` the geometry marks never carried. Feeding `lastPosted` — the real script's
    /// output, not a hand-typed literal — through the real gate is what would have caught it: a
    /// JS key rename fails here even though `decode` never sees it.
    func testEveryMarkThePagePostsIsAdmittedByTheRealGate() throws {
        let selection = try CanvasScriptRuntime()
        selection.setTool(.text)
        selection.select(id: "intro", text: "Why this exists")
        selection.mouse("mouseup", 100, 110)
        guard
            case .selected = try CanvasPageSelection.decode(
                try XCTUnwrap(selection.lastPosted)
            ).get()
        else {
            return XCTFail("a selection must be admitted by the gate")
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
        // set below reads as though every tool maps onto a kind, and the one that maps onto
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
            ["selection", "cleared"],
            "a third kind was declared in Swift and this test was not extended to make the "
                + "script produce one — so nothing measures whether the page can post it")
    }

    /// The dismissal is the one message that deliberately decodes to nothing — it closes the
    /// comment field rather than writing a note.
    func testADismissalIsRefusedByTheDecoderRatherThanBecomingANote() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
        page.mouse("mouseup", 100, 110)

        XCTAssertNil(
            CanvasAnnotation.decode(posted: try XCTUnwrap(page.lastPosted), comment: "a comment"))
    }

    private func decode(_ body: [String: Any]?) throws -> CanvasAnnotation.Mark {
        let annotation = try XCTUnwrap(
            CanvasAnnotation.decode(posted: try XCTUnwrap(body), comment: "a comment"),
            "the page posted a payload the real decoder refuses")
        return annotation.mark
    }
}
