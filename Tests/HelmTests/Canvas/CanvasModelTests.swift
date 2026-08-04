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

    /// What the bridge reports when the operator selects `payload["text"]` on the page.
    private func selection(_ payload: [String: Any]) throws -> CanvasPageSelection {
        .selected(try XCTUnwrap(CanvasSelection(payload)))
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
        let model = CanvasModel()
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
        let model = CanvasModel()
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
        let model = CanvasModel()
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
        let model = CanvasModel()
        model.open(file)

        model.annotate(comment: "this ordering is wrong")

        XCTAssertNil(model.notesFailure, "there was no attempt to fail")
        XCTAssertEqual(model.notes, [])
    }

    /// A URL canvas has no file to write beside, so there is no sidecar and nothing to
    /// annotate — the same reason `fileURL` is nil for one.
    func testAURLCanvasHasNowhereToPutANote() throws {
        let model = CanvasModel()
        model.openURL(URL(string: "https://example.com/dashboard")!)
        model.pageDidReport(try selection(["text": "a passage"]))

        model.annotate(comment: "why?")

        XCTAssertNil(model.sidecarURL)
        XCTAssertNil(model.notesFailure)
        XCTAssertEqual(model.notes, [])
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
        let model = CanvasModel()
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
        XCTAssertNil(CanvasPageSelection("not a payload at all"))
        XCTAssertNil(CanvasPageSelection(["cleared": "yes"]), "a string is not the flag")

        guard case .cleared = try XCTUnwrap(CanvasPageSelection(["cleared": true])) else {
            return XCTFail("a cleared body is a dismissal")
        }
        guard
            case let .selected(selection) = try XCTUnwrap(
                CanvasPageSelection(["id": "phase-2", "text": "Phase 2"]))
        else {
            return XCTFail("a body with a selection in it is one")
        }
        XCTAssertEqual(selection.body["id"] as? String, "phase-2")
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
        // Otherwise getting back to reading the page means remembering which icon is select.
        let model = CanvasModel()
        model.pick(.arrow)

        model.pick(.arrow)

        XCTAssertEqual(model.markTool, .select)
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
        XCTAssertEqual(CanvasModel().markTool, .select)
    }
}
