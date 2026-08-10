import XCTest

@testable import Helm

/// The canvas's two sources and the seam between them. No window and no WebKit:
/// everything here is the model deciding what the pane is showing.
@MainActor
final class CanvasModelTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-canvas-\(UUID().uuidString).md")
        try "# plan".write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func page(of model: CanvasModel) -> CanvasModel.Page? {
        if case let .url(page) = model.showing { page } else { nil }
    }

    /// **A canvas whose clipboard is this suite's rather than the operator's**, and what every test
    /// below that reaches `annotate` is built with. With no `onAnnotation` wired the delivery is
    /// `.notSent(.noOrigin)`, which copies — and the default sink is `NSPasteboard.general`, the
    /// clipboard of whoever is running the gate. `CanvasModel.copyToClipboard`'s header has the
    /// argument; `PasteboardTests`'s has the older half of it.
    private func quietCanvas() -> CanvasModel {
        let model = CanvasModel()
        model.copyToClipboard = { _ in }
        return model
    }

    /// What the bridge reports when the operator selects `payload["text"]` on the page — with
    /// `kind: "selection"` filled in, because every message has declared one since #109 and
    /// `annotate` decodes this body again downstream. Filling the kind in here rather than in a
    /// dozen fixtures keeps these tests about their own subjects;
    /// `testTheGateAsksTheKindAndRefusesOneItDoesNotKnow` is where the kind itself is the subject.
    ///
    /// **Built through `CanvasPageSelection.decode`, not around it** (#298). This used to call
    /// `CanvasSelection.init` and wrap the result in `.selected` itself, which held the fixture to
    /// nothing at all — the decoder's rules are `kind`, a known one, and text on a `selection`,
    /// and a fixture assembled beside the gate keeps constructing a body no page can post long
    /// after the wire has moved. `CanvasCommentFieldReturnTests` paid that in #293: the fixture
    /// went stale the moment #288 made `kind` the discriminator, and CI said *"Enter no longer
    /// writes the note"* across three tests while Enter was working perfectly. Going through the
    /// decoder makes the next wire change fail **here**, at construction, quoting the decoder's
    /// own refusal. `init` is `fileprivate` now, so this is the only door there is.
    ///
    /// `file`/`line` default from the caller, so a refusal is reported at the test that asked
    /// rather than at this line — `XCTFail`'s own defaults are captured where it is written, and
    /// a whole suite pointing here would be the drift's location rather than its subject.
    private func selection(
        _ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) throws -> CanvasPageSelection {
        var payload = payload
        payload["kind"] = payload["kind"] ?? CanvasPageSelection.Kind.selection.rawValue
        switch CanvasPageSelection.decode(payload) {
        case let .success(.selected(selection)):
            return .selected(selection)
        case .success(.cleared):
            XCTFail(
                "this helper builds a selection, and \(payload) decoded as a dismissal",
                file: file, line: line)
            throw CanvasPageSelection.Refusal.malformed(.selection)
        case let .failure(refusal):
            XCTFail(
                "the page-selection fixture these tests are built on is not a message helm "
                    + "accepts any more — \(refusal.reason). Rebuild it to the shape "
                    + "`CanvasPageSelection.decode` takes; do not loosen the decoder.",
                file: file, line: line)
            throw refusal
        }
    }

    // MARK: - File source or URL source

    func testAURLSourceExposesNoFilePath() {
        // `fileURL` answers "is there a file here", and the live readers depend on it:
        // `sidecarURL` writes notes beside that file, and reveal-in-Finder opens it. A
        // URL leaking into it would put a canvas's notes beside a path that is not one.
        // (What *persists* is `CanvasSource`, through the bench — not this.)
        let model = CanvasModel()
        model.open(file)
        XCTAssertEqual(model.fileURL, file)

        model.openURL(URL(string: "https://example.com/dashboard")!)
        XCTAssertNil(model.fileURL, "a URL canvas must persist no path at all")
        XCTAssertTrue(model.isOpen, "it is still an open canvas, just not a file one")
    }

    // MARK: - ⌘L

    func testFocusAddressOpensAnEmptyPageOnAClosedCanvas() {
        let model = CanvasModel()
        model.focusAddress()

        XCTAssertNil(page(of: model)?.url, "nothing is loaded until an address is committed")
        XCTAssertEqual(page(of: model)?.address, "")
        XCTAssertEqual(model.addressFocus, 1)
    }

    func testFocusAddressKeepsThePageItIsAlreadyShowing() {
        // ⌘L on an open canvas is "edit this address", not "start over" — and the
        // counter still rises so the field re-focuses.
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.focusAddress()

        XCTAssertEqual(page(of: model)?.url?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(model.addressFocus, 1)
    }

    func testFocusAddressReplacesAFileSource() {
        let model = CanvasModel()
        model.open(file)
        model.focusAddress()

        XCTAssertNotNil(page(of: model), "single pane: the URL source takes it over")
        XCTAssertNil(model.fileURL)
    }

    // MARK: - Committing an address

    func testSubmitLoadsAParseableAddress() {
        let model = CanvasModel()
        model.focusAddress()
        model.submitAddress("localhost:3000")

        XCTAssertEqual(page(of: model)?.url?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(page(of: model)?.address, "http://localhost:3000")
        XCTAssertNil(page(of: model)?.failure)
    }

    func testSubmitKeepsThePageAndSaysWhyWhenTheAddressIsRefused() {
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.submitAddress("ssh://root@evil.example")

        XCTAssertEqual(
            page(of: model)?.url?.absoluteString, "http://localhost:3000",
            "a typo must not blank the canvas")
        XCTAssertEqual(page(of: model)?.address, "ssh://root@evil.example")
        XCTAssertNotNil(page(of: model)?.failure, "a refusal is never silent")
    }

    func testSubmitIgnoresAFileSource() {
        let model = CanvasModel()
        model.open(file)
        model.submitAddress("localhost:3000")

        XCTAssertEqual(model.fileURL, file, "there is no address bar on a file canvas")
    }

    // MARK: - Loading again

    func testResubmittingTheSameAddressStillRetries() {
        // The ordinary case: the dev server was not up yet. The view loads on a
        // (url, generation) key, so an unchanged URL has to move the counter.
        let model = CanvasModel()
        model.focusAddress()
        model.submitAddress("localhost:3000")
        let first = page(of: model)?.generation
        model.submitAddress("localhost:3000")

        XCTAssertEqual(page(of: model)?.generation, (first ?? 0) + 1)
    }

    func testReloadBumpsTheCounterAndClearsTheFailure() {
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.pageDidFail("Could not connect to the server.")
        let before = page(of: model)?.generation

        model.reloadPage()

        XCTAssertEqual(page(of: model)?.generation, (before ?? 0) + 1)
        XCTAssertNil(page(of: model)?.failure)
    }

    func testReloadDoesNothingWithNothingLoaded() {
        let model = CanvasModel()
        model.focusAddress()
        model.reloadPage()

        XCTAssertEqual(page(of: model)?.generation, 0)
    }

    // MARK: - What the page reports back

    func testNavigationFollowsTheAddressFieldAndClearsTheFailure() {
        // A link click has to move the field, or reload would reload something
        // other than what is on screen.
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.pageDidFail("stale")
        let before = page(of: model)?.generation

        model.pageDidNavigate(to: URL(string: "http://localhost:3000/about")!)

        XCTAssertEqual(page(of: model)?.address, "http://localhost:3000/about")
        XCTAssertEqual(page(of: model)?.url?.absoluteString, "http://localhost:3000/about")
        XCTAssertNil(page(of: model)?.failure)
        XCTAssertEqual(
            page(of: model)?.generation, before,
            "reporting where the page went must not ask the view to load it again")
    }

    func testFailureIsHeldOnThePage() {
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.pageDidFail("Could not connect to the server.")

        XCTAssertEqual(page(of: model)?.failure, "Could not connect to the server.")
        XCTAssertEqual(
            page(of: model)?.url?.absoluteString, "http://localhost:3000",
            "the address stays so reload can retry it")
    }

    func testAFileSourceIgnoresPageCallbacks() {
        let model = CanvasModel()
        model.open(file)
        model.pageDidFail("not mine")
        model.pageDidNavigate(to: URL(string: "http://example.com")!)

        XCTAssertEqual(model.fileURL, file)
    }

    // MARK: - Annotating

    // `CanvasAnnotation.decode` and `CanvasNotes.append` are each tested on their own.
    // What is only decidable here is what happens to the **selection** when either
    // refuses — because the selection is the operator's place in the document, and
    // throwing it away on a failure means they have to find it again to retry.

    func testAnnotatingWritesTheNoteAndClearsTheSelection() throws {
        let model = quietCanvas()
        model.open(file)
        model.pageDidReport(try selection(["id": "phase-2", "text": "Phase 2"]))

        model.annotate(comment: "this ordering is wrong")

        XCTAssertNil(model.notesFailure)
        XCTAssertNil(model.selection, "the comment landed, so the field has nothing left to do")
        XCTAssertEqual(
            model.notes, ["`#phase-2` — \"Phase 2\""],
            "the count in the pane header is read back off the sidecar, not tallied here")
        addTeardownBlock { [sidecar = model.sidecarURL] in
            if let sidecar { try? FileManager.default.removeItem(at: sidecar) }
        }
    }

    func testAnUnanchorableSelectionKeepsTheSelectionAndSaysSo() throws {
        let model = quietCanvas()
        model.open(file)
        model.pageDidReport(try selection(["text": "a passage"]))

        // An empty comment is what `CanvasAnnotation.decode` refuses — there is nothing
        // to anchor.
        model.annotate(comment: "   ")

        XCTAssertNotNil(model.notesFailure)
        XCTAssertNotNil(
            model.selection,
            "dropping the selection on a refusal would make the operator find their place "
                + "again before they could retry")
        XCTAssertEqual(model.notes, [], "and nothing was written")
    }

    func testAWriteFailureReachesThePaneNamingTheFile() throws {
        let model = quietCanvas()
        // A canvas opened through Browse… can live somewhere not writable.
        model.open(URL(fileURLWithPath: "/System/helm-should-not-write-here/plan.md"))
        model.pageDidReport(try selection(["text": "a passage"]))

        model.annotate(comment: "why?")

        let failure = try XCTUnwrap(model.notesFailure)
        XCTAssertTrue(
            failure.contains("plan.notes.md"), "a failure that does not name the file is a shrug")
        XCTAssertNotNil(model.selection, "the note was not written, so the selection stands")
    }

    func testAnnotatingWithoutASelectionDoesNothingAtAll() {
        let model = quietCanvas()
        model.open(file)

        model.annotate(comment: "this ordering is wrong")

        XCTAssertNil(model.notesFailure, "there was no attempt to fail")
        XCTAssertEqual(model.notes, [])
    }

    /// A URL canvas has no file to write beside, so there is no sidecar and nothing to
    /// annotate — the same reason `fileURL` is nil for one.
    func testAURLCanvasHasNowhereToPutANote() throws {
        let model = quietCanvas()
        model.openURL(URL(string: "https://example.com/dashboard")!)
        model.pageDidReport(try selection(["text": "a passage"]))

        model.annotate(comment: "why?")

        XCTAssertNil(model.sidecarURL)
        XCTAssertNil(model.notesFailure)
        XCTAssertEqual(model.notes, [])
    }

    // MARK: - Geometry marks reach the model (#216)

    // `CanvasMarkTests` drives `CanvasAnnotation.decode` directly with hand-built enclosure and
    // relation dictionaries; the tests above go through the real gate — `CanvasPageSelection
    // .decode` at `CanvasFileViews.swift` — but only ever as a `selection`, because that is the
    // kind the helper fills in. Neither pushes a GEOMETRY payload through it. That gate required
    // a top-level `text`, which an enclosure and a relation never carry, so both were silently
    // dropped before decode ever saw them. These two go through it exactly as the page posts
    // them, and would have failed before the fix.
    //
    // The helper stopped being a way *around* that gate in #298: `CanvasSelection.init` is
    // `fileprivate`, so `decode` is the only thing that can make one. What these two still buy
    // that it cannot is the kinds it does not post.

    /// The page's freehand tool: `bridge.postMessage({ kind: "enclosure", targets, rect })`.
    func testAnEnclosurePayloadReachesTheNoteThroughTheRealGate() throws {
        let model = quietCanvas()
        model.open(file)

        let report = try CanvasPageSelection.decode([
            "kind": "enclosure",
            "targets": [["id": "phase-2", "text": "Phase 2: Ship"]],
            "rect": ["x": 10, "y": 20, "width": 30, "height": 40],
        ]).get()
        model.pageDidReport(report)
        XCTAssertNotNil(model.selection, "an enclosure is a selection, exactly as text is")

        model.annotate(comment: "these two are the same step")

        XCTAssertNil(model.notesFailure)
        XCTAssertEqual(model.notes, ["circled `#phase-2` — \"Phase 2: Ship\""])
        addTeardownBlock { [sidecar = model.sidecarURL] in
            if let sidecar { try? FileManager.default.removeItem(at: sidecar) }
        }
    }

    /// The page's arrow tool: `bridge.postMessage({ kind: "relation", from, to, rect })`.
    func testARelationPayloadReachesTheNoteThroughTheRealGate() throws {
        let model = quietCanvas()
        model.open(file)

        let report = try CanvasPageSelection.decode([
            "kind": "relation",
            "from": ["id": "phase-1", "text": "One"],
            "to": ["id": "phase-3", "text": "Three"],
            "rect": ["x": 0, "y": 0, "width": 0, "height": 0],
        ]).get()
        model.pageDidReport(report)
        XCTAssertNotNil(model.selection, "a relation is a selection, exactly as text is")

        model.annotate(comment: "this should point the other way")

        XCTAssertNil(model.notesFailure)
        XCTAssertEqual(model.notes, ["arrow `#phase-1` → `#phase-3`"])
        addTeardownBlock { [sidecar = model.sidecarURL] in
            if let sidecar { try? FileManager.default.removeItem(at: sidecar) }
        }
    }

    // MARK: - Dismissing

    // #165: the comment field's only exit was `.onExitCommand` in the view, which travels
    // the responder chain — so Escape stopped working the moment focus left the field, and
    // there was then no way to close the box at all. **What can dismiss a selection is the
    // model's decision**, so it is decided and tested here rather than in a `View` no test
    // can drive.

    func testDismissingClearsTheSelectionAndWritesNothing() throws {
        let model = CanvasModel()
        model.open(file)
        model.pageDidReport(try selection(["id": "phase-2", "text": "Phase 2"]))

        // The field's ✕, and Escape while it has focus. Neither needs a responder chain to
        // reach the model, which is the whole point.
        model.dismissSelection()

        XCTAssertNil(model.selection, "the field has nothing left to be about")
        XCTAssertEqual(model.notes, [], "a dismissal abandons the note rather than writing it")
    }

    func testAClickThatSelectedNothingDismissesTheField() throws {
        let model = CanvasModel()
        model.open(file)
        model.pageDidReport(try selection(["text": "a passage"]))
        XCTAssertNotNil(model.selection)

        // The page's `mouseup` with an empty selection: clicking elsewhere in the document.
        model.pageDidReport(.cleared)

        XCTAssertNil(model.selection, "click-elsewhere-to-dismiss, the same as any popover")
    }

    func testDismissingTakesTheFailureStripWithIt() throws {
        let model = quietCanvas()
        model.open(file)
        model.pageDidReport(try selection(["text": "a passage"]))
        // An empty comment is what `CanvasAnnotation.decode` refuses.
        model.annotate(comment: "   ")
        XCTAssertNotNil(model.notesFailure, "the strip is up, and the selection with it")

        model.dismissSelection()

        XCTAssertNil(
            model.notesFailure,
            "\"try selecting the text again\" would be naming a selection that is gone")
    }

    /// **The decision on focus loss, stated as a test.** A selection is not dropped by
    /// anything except a dismissal — going to a terminal to read what the agent said about
    /// a passage and coming back to comment on it is the ordinary annotation loop, and the
    /// model has no path that ends it. Only these three do, and all three are canvas-local
    /// acts by the operator.
    func testASelectionSurvivesEverythingThatIsNotADismissal() throws {
        let model = CanvasModel()
        model.open(file)
        model.pageDidReport(try selection(["text": "a passage"]))

        model.refreshNotes()
        model.reloadPage()

        XCTAssertNotNil(
            model.selection,
            "only a submit, a dismissal, or opening another source may take the field away")
    }

    /// The bridge is the untrusted edge, so a body that is neither must be dropped rather
    /// than rounded down to "cleared" — that would let a malformed message close a field the
    /// operator was typing in.
    func testOnlyARecognisedBodyIsAReport() throws {
        XCTAssertEqual(
            CanvasPageSelection.decode("not a payload at all").refusal, .notAnObject)

        guard case .cleared = try CanvasPageSelection.decode(["kind": "cleared"]).get() else {
            return XCTFail("a cleared body is a dismissal")
        }
        guard
            case let .selected(selection) = try CanvasPageSelection.decode([
                "kind": "selection", "id": "phase-2", "text": "Phase 2",
            ]).get()
        else {
            return XCTFail("a body with a selection in it is one")
        }
        XCTAssertEqual(selection.body["id"] as? String, "phase-2")
    }

    /// **The discriminator, at the gate** (#109). Every message the page posts says what it is,
    /// the gate asks only that one field, and a kind this build has not learned is refused with
    /// the kind named — never inferred from which fields happen to be present, which is what
    /// dropped every geometry mark for months (#216).
    func testTheGateAsksTheKindAndRefusesOneItDoesNotKnow() {
        XCTAssertEqual(
            CanvasPageSelection.decode(["kind": "lasso", "id": "a", "text": "b"]).refusal,
            .unknownKind("lasso"),
            "a kind helm does not know must be refused BY NAME. Falling through to a selection "
                + "would put the comment field over whatever text the payload happened to carry "
                + "and write a note that says the wrong thing about the wrong gesture")

        XCTAssertEqual(
            CanvasPageSelection.decode(["id": "phase-2", "text": "Phase 2"]).refusal, .noKind,
            "the shape used to BE the kind — `text` present meant selection. That inference is "
                + "what #216 is, and a payload with no kind is now a message rather than a guess")

        XCTAssertEqual(
            CanvasPageSelection.decode(["kind": "selection", "text": "   "]).refusal,
            .malformed(.selection),
            "an empty selection would put an empty comment box over the page")

        for kind in CanvasPageSelection.Kind.allCases {
            XCTAssertNotEqual(
                CanvasPageSelection.decode(["kind": kind.rawValue, "text": "something"]).refusal,
                .unknownKind(kind.rawValue),
                "\(kind.rawValue) is a kind this build declares and must never be refused as "
                    + "unknown — a `Kind` case with no branch behind it is the drift the "
                    + "exhaustive switch exists to prevent")
        }
    }

    // MARK: - Closing

    func testCloseEmptiesTheCanvasFromEitherSource() {
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.close()
        XCTAssertFalse(model.isOpen)

        model.open(file)
        model.close()
        XCTAssertFalse(model.isOpen)
    }

    // MARK: - Picking a mark tool (#112)

    @MainActor
    func testPickingAToolHoldsIt() {
        let model = CanvasModel()

        model.pick(.freehand)

        XCTAssertEqual(model.markTool, .freehand)
    }

    @MainActor
    func testPickingTheHeldToolPutsItDown() {
        // Otherwise getting back to reading the page means remembering which icon reads.
        let model = CanvasModel()
        model.pick(.arrow)

        model.pick(.arrow)

        XCTAssertEqual(
            model.markTool, .read,
            "putting a tool down has to land on the inert mode, not on a second armed one")
    }

    /// #302: `.read` is the state, so asking for it is not a request to leave it. The toggle
    /// rule is written as "the held tool puts itself down", and `.read` is the one tool that
    /// rule could turn into a way of arming the canvas by pressing the button that disarms it.
    @MainActor
    func testPickingReadWhileAlreadyReadingStaysReading() {
        let model = CanvasModel()

        model.pick(.read)

        XCTAssertEqual(model.markTool, .read)
    }

    /// The other half: `.read` is reachable from a held tool by name, not only by the toggle.
    /// The picker draws a button for it, so this is the rule that button spends.
    @MainActor
    func testPickingReadPutsDownWhateverWasHeld() {
        let model = CanvasModel()
        model.pick(.freehand)

        model.pick(.read)

        XCTAssertEqual(model.markTool, .read)
    }

    @MainActor
    func testPickingAnotherToolSwapsRatherThanClears() {
        let model = CanvasModel()
        model.pick(.arrow)

        model.pick(.point)

        XCTAssertEqual(model.markTool, .point)
    }

    @MainActor
    func testACanvasNobodyHasTouchedIsReading() {
        XCTAssertEqual(
            CanvasModel().markTool, .read,
            "a canvas nobody has picked a tool up on must interpret nothing (#302)")
    }
}

/// Why a decode was refused, for the suites that assert on it.
///
/// `CanvasPageSelection.decode` returns a `Result` rather than an optional precisely so the
/// reason survives — a message dropped without one is #216 — and this is what lets a test say
/// *which* refusal it expected instead of "not nil". `.get()` is the other half, for the tests
/// that expect a message rather than a refusal.
extension Result where Success == CanvasPageSelection, Failure == CanvasPageSelection.Refusal {
    var refusal: CanvasPageSelection.Refusal? {
        if case let .failure(refusal) = self { refusal } else { nil }
    }
}
