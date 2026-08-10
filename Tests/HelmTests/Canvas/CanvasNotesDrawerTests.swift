import XCTest

@testable import Helm

/// The sidecar drawer (#198): what opens it, what closes it, and what it has to render.
///
/// **The state is on the model, so this is where the drawer is decidable.** It lives beside
/// `markTool` for the same reason — the pane is rebuilt on ordinary SwiftUI churn — and that
/// is exactly what makes "the Notes button toggles it" and "a click on the canvas puts it
/// away" testable without a window. What is NOT here is the drawing: that Escape reaches the
/// key equivalent over a WKWebView, and that the panel lands over the trailing half, are
/// facts about AppKit and can only be seen in a running helm.
@MainActor
final class CanvasNotesDrawerTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-canvas-drawer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("plan.md")
        try "# plan".write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// What the bridge reports when the operator selects `text` on the page — `kind` filled in,
    /// as every bridge message has carried one since #109.
    ///
    /// **Built through `CanvasPageSelection.decode`, not around it** (#298), for the reason
    /// `CanvasModelTests.selection(_:)`'s header gives at length: a fixture assembled beside the
    /// gate goes stale silently when the wire moves, and reports the drift as whatever behaviour
    /// the test was about. Through the decoder it fails here, at construction, naming the refusal.
    private func selection(_ payload: [String: Any]) throws -> CanvasPageSelection {
        var payload = payload
        payload["kind"] = payload["kind"] ?? CanvasPageSelection.Kind.selection.rawValue
        switch CanvasPageSelection.decode(payload) {
        case let .success(.selected(selection)):
            return .selected(selection)
        case .success(.cleared):
            XCTFail("this helper builds a selection, and \(payload) decoded as a dismissal")
            throw CanvasPageSelection.Refusal.malformed(.selection)
        case let .failure(refusal):
            XCTFail(
                "the page-selection fixture these tests are built on is not a message helm "
                    + "accepts any more — \(refusal.reason). Rebuild it to the shape "
                    + "`CanvasPageSelection.decode` takes; do not loosen the decoder.")
            throw refusal
        }
    }

    private func writeSidecar(_ text: String) throws {
        try text.write(
            to: CanvasNotes.sidecarURL(for: file), atomically: true, encoding: .utf8)
    }

    /// **A canvas whose clipboard is this suite's rather than the operator's**, for the one test
    /// below that reaches `annotate`. With no `onAnnotation` wired the delivery is
    /// `.notSent(.noOrigin)`, which copies — and the default sink is `NSPasteboard.general`.
    /// `CanvasModel.copyToClipboard`'s header has the argument.
    private func quietCanvas() -> CanvasModel {
        let model = CanvasModel()
        model.copyToClipboard = { _ in }
        return model
    }

    // MARK: - Opening and closing

    func testTheNotesButtonOpensAndClosesTheDrawer() throws {
        try writeSidecar("## \"a passage\"\n\nthis ordering is wrong\n")
        let model = CanvasModel()
        model.open(file)

        XCTAssertFalse(model.showsNotes, "a canvas opens showing the artifact, not its notes")
        model.toggleNotes()
        XCTAssertTrue(model.showsNotes)
        model.toggleNotes()
        XCTAssertFalse(model.showsNotes, "the same button is the way back out")
    }

    func testAClickOnTheCanvasThatSelectedNothingPutsTheDrawerAway() throws {
        try writeSidecar("## \"a passage\"\n\nthis ordering is wrong\n")
        let model = CanvasModel()
        model.open(file)
        model.toggleNotes()

        // The page's `mouseup` with an empty selection: clicking on the artifact.
        model.pageDidReport(.cleared)

        XCTAssertFalse(model.showsNotes, "the drawer is over the thing you just clicked on")
    }

    func testAbandoningACommentLeavesTheDrawerWhereItWas() throws {
        try writeSidecar("## \"a passage\"\n\nthis ordering is wrong\n")
        let model = CanvasModel()
        model.open(file)
        model.toggleNotes()
        model.pageDidReport(try selection(["text": "a passage"]))

        // The field's own ✕, or Escape while it has focus.
        model.dismissSelection()

        XCTAssertTrue(
            model.showsNotes,
            "giving up on a comment says nothing about whether the notes are still wanted")
    }

    func testOpeningAnotherArtifactClosesTheDrawer() throws {
        try writeSidecar("## \"a passage\"\n\nthis ordering is wrong\n")
        let model = CanvasModel()
        model.open(file)
        model.toggleNotes()

        let other = directory.appendingPathComponent("tasks.md")
        try "# tasks".write(to: other, atomically: true, encoding: .utf8)
        model.open(other)

        XCTAssertFalse(
            model.showsNotes,
            "carried over, the drawer would be open on notes the operator never asked to see")
        XCTAssertNil(model.notesText, "and it would be the previous artifact's sidecar in it")
    }

    // MARK: - The drawer and the comment field, together

    func testASelectionLeavesTheDrawerOpen() throws {
        try writeSidecar("## \"a passage\"\n\nthis ordering is wrong\n")
        let model = CanvasModel()
        model.open(file)
        model.toggleNotes()

        model.pageDidReport(try selection(["id": "phase-2", "text": "Phase 2"]))

        XCTAssertNotNil(model.selection)
        XCTAssertTrue(
            model.showsNotes,
            "reading what you already said while writing the next one is the ordinary case")
    }

    func testTheCommentFieldTakesEscapeFirst() throws {
        try writeSidecar("## \"a passage\"\n\nthis ordering is wrong\n")
        let model = CanvasModel()
        model.open(file)
        model.toggleNotes()
        XCTAssertTrue(model.escapeClosesNotes)

        model.pageDidReport(try selection(["text": "a passage"]))

        XCTAssertFalse(
            model.escapeClosesNotes,
            "the drawer's Escape is a key equivalent and fires before the focused field is "
                + "ever asked — it must stand down while there is a field to abandon")

        model.dismissSelection()
        XCTAssertTrue(model.escapeClosesNotes, "and take it back when the field is gone")
    }

    func testANoteWrittenWhileTheDrawerIsOpenAppearsInIt() throws {
        let model = quietCanvas()
        model.open(file)
        model.pageDidReport(try selection(["id": "phase-2", "text": "Phase 2"]))
        model.toggleNotes()

        model.annotate(comment: "this ordering is wrong")

        XCTAssertTrue(model.showsNotes, "the drawer stays up — it is what you are writing into")
        let rendered = try XCTUnwrap(model.notesText)
        XCTAssertTrue(rendered.contains("this ordering is wrong"), "with the new note in it")
        XCTAssertEqual(model.notes.count, 1, "and the header's count agrees with it")
    }

    // MARK: - What there is to render

    func testTheDrawerRendersTheWholeSidecarAndNotJustItsHeadings() throws {
        try writeSidecar(
            """
            ## `#phase-2` — "Phase 2"

            this ordering is wrong — ship the migration first

            <sub>2026-08-05 14:02</sub>

            """)
        let model = CanvasModel()
        model.open(file)

        let rendered = try XCTUnwrap(model.notesText)
        XCTAssertTrue(
            rendered.contains("ship the migration first"),
            "the comment is the thing the popover never showed — it is the whole issue")
        XCTAssertEqual(model.notesMarkdown, rendered, "Post hands over exactly what is drawn")
    }

    func testASidecarWithNoHeadingsIsStillOfferedAndStillReadable() throws {
        // An agent appending prose beside the canvas, with no `##` entry of helm's own.
        try writeSidecar("the plan reads well, but the ordering is off.\n")
        let model = CanvasModel()
        model.open(file)

        XCTAssertEqual(model.notes, [], "nothing to count")
        XCTAssertTrue(
            model.hasNotes,
            "but something to read — a button that hid it would be this issue over again")
        XCTAssertEqual(model.notesText, "the plan reads well, but the ordering is off.\n")
    }

    func testAnEmptySidecarHasNothingToRenderAndNothingToPost() throws {
        try writeSidecar("   \n\n")
        let model = CanvasModel()
        model.open(file)

        XCTAssertNil(model.notesText, "the drawer reads as empty rather than as broken")
        XCTAssertNil(model.notesMarkdown, "and there is nothing to hand to a composer")
        XCTAssertFalse(model.hasNotes)
    }

    func testAURLCanvasHasNoSidecarToOpen() {
        let model = CanvasModel()
        model.openURL(URL(string: "https://example.com/dashboard")!)

        XCTAssertNil(model.sidecarURL, "which is what keeps a drawer off a web page")
    }

    // MARK: - How wide

    func testTheDrawerTakesHalfOfAnOrdinaryPane() {
        XCTAssertEqual(CanvasNotesDrawerMetrics.width(inPaneOf: 900), 450)
        XCTAssertEqual(CanvasNotesDrawerMetrics.width(inPaneOf: 1200), 600)
    }

    func testANarrowPaneGivesTheDrawerMoreThanHalfRatherThanARibbon() {
        // Half of 400 is 200pt of prose, which is a column of two-word lines.
        XCTAssertEqual(CanvasNotesDrawerMetrics.width(inPaneOf: 400), 280)
    }

    func testTheProseStopsAtAReadingMeasureHoweverWideTheDrawerIs() {
        // Half of an ultrawide is 1700pt, and prose set to that is 200 characters a line.
        XCTAssertEqual(
            CanvasNotesDrawerMetrics.textWidth(inDrawerOf: 1720),
            CanvasNotesDrawerMetrics.measure,
            "the panel takes half; the text stops at the artifact's own measure")
        XCTAssertEqual(
            CanvasNotesDrawerMetrics.textWidth(inDrawerOf: 320), 292,
            "and fills a narrow one, inset either side")
    }

    func testTheDrawerIsNeverWiderThanThePaneItIsOver() {
        XCTAssertEqual(
            CanvasNotesDrawerMetrics.width(inPaneOf: 220), 220,
            "hanging off the edge would put Post and Reveal — the only route to either — "
                + "outside the window")
        XCTAssertEqual(
            CanvasNotesDrawerMetrics.width(inPaneOf: 0), CanvasNotesDrawerMetrics.minimum,
            "a pane with no measured width yet must not collapse the drawer to nothing")
    }
}
