import XCTest

@testable import Helm

/// The return path: where notes land, what they look like, and that appending never loses
/// what was already there.
final class CanvasNotesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-canvas-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let stamp = Date(timeIntervalSince1970: 0)

    // MARK: - Where

    func testTheSidecarSitsBesideTheCanvas() {
        XCTAssertEqual(
            CanvasNotes.sidecarURL(for: URL(fileURLWithPath: "/p/canvas/tasks.html")).path,
            "/p/canvas/tasks.notes.md")
        XCTAssertEqual(
            CanvasNotes.sidecarURL(for: URL(fileURLWithPath: "/p/canvas/plan.md")).path,
            "/p/canvas/plan.notes.md")
        XCTAssertEqual(
            CanvasNotes.sidecarURL(for: URL(fileURLWithPath: "/p/canvas/README")).path,
            "/p/canvas/README.notes.md",
            "no extension is not a reason to write beside the wrong file")
    }

    func testTheSidecarIsBesideTheCanvasEvenOutsideAStore() {
        XCTAssertEqual(
            CanvasNotes.sidecarURL(for: URL(fileURLWithPath: "/Users/x/Desktop/notes.md")).path,
            "/Users/x/Desktop/notes.notes.md",
            "a canvas opened through Browse… can live anywhere; its notes go with it")
    }

    // MARK: - What

    func testAnElementAnchorNamesTheIDTheAgentCanEdit() {
        let entry = CanvasNotes.entry(
            CanvasAnnotation(
                anchor: .element(id: "phase-2", text: "Phase 2 — migrate the store"),
                comment: "this ordering is wrong, the store move has to come first"),
            at: stamp)

        XCTAssertTrue(
            entry.contains("## `#phase-2` — \"Phase 2 — migrate the store\""), entry)
        XCTAssertTrue(
            entry.contains("this ordering is wrong, the store move has to come first"), entry)
    }

    func testAQuoteAnchorNamesTheTextAlone() {
        let entry = CanvasNotes.entry(
            CanvasAnnotation(anchor: .quote("the store move"), comment: "why?"), at: stamp)

        XCTAssertTrue(entry.contains("## \"the store move\""), entry)
        XCTAssertFalse(entry.contains("#`"), "there was no id to name")
    }

    func testAMultiLineSelectionStaysOnOneHeadingLine() {
        let entry = CanvasNotes.entry(
            CanvasAnnotation(anchor: .quote("first line\nsecond line"), comment: "hm"), at: stamp)

        let heading = entry.split(separator: "\n").first { $0.hasPrefix("## ") }
        XCTAssertEqual(
            heading, "## \"first line second line\"",
            "a newline in a heading would break the markdown the agent is meant to read")
    }

    // MARK: - Appending

    func testAppendPreservesExistingContentByteForByte() throws {
        let canvas = directory.appendingPathComponent("tasks.html")
        let sidecar = CanvasNotes.sidecarURL(for: canvas)
        let existing = "## `#phase-1` — \"Phase 1\"\n\nan earlier note\n\n"
        try existing.write(to: sidecar, atomically: true, encoding: .utf8)

        try CanvasNotes.append(
            CanvasAnnotation(anchor: .quote("later"), comment: "a second note"),
            for: canvas, at: stamp)

        let written = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(
            written.hasPrefix(existing),
            "the sidecar is the memory — a rewrite would lose earlier notes and race the "
                + "operator, who may have the file open")
        XCTAssertTrue(written.contains("a second note"))
    }

    func testAppendCreatesTheSidecarWhenThereIsNoneYet() throws {
        let canvas = directory.appendingPathComponent("plan.md")

        try CanvasNotes.append(
            CanvasAnnotation(anchor: .quote("a passage"), comment: "first"), for: canvas,
            at: stamp)

        let written = try XCTUnwrap(CanvasNotes.markdown(in: CanvasNotes.sidecarURL(for: canvas)))
        XCTAssertEqual(CanvasNotes.headings(in: written).count, 1)
    }

    /// A canvas opened through Browse… can live somewhere not writable. The failure has to
    /// reach the pane; it must never be swallowed.
    func testAnUnwritableDirectoryThrowsRatherThanFailingQuietly() {
        let canvas = URL(fileURLWithPath: "/System/helm-should-not-write-here/plan.md")

        XCTAssertThrowsError(
            try CanvasNotes.append(
                CanvasAnnotation(anchor: .quote("x"), comment: "y"), for: canvas, at: stamp))
    }

    func testHeadingsAndMarkdownReadBackWhatWasWritten() throws {
        let canvas = directory.appendingPathComponent("tasks.html")
        try CanvasNotes.append(
            CanvasAnnotation(anchor: .element(id: "a", text: "A"), comment: "one"), for: canvas,
            at: stamp)
        try CanvasNotes.append(
            CanvasAnnotation(anchor: .quote("B"), comment: "two"), for: canvas, at: stamp)

        let sidecar = CanvasNotes.sidecarURL(for: canvas)
        let written = try XCTUnwrap(CanvasNotes.markdown(in: sidecar))
        XCTAssertEqual(CanvasNotes.headings(in: written), ["`#a` — \"A\"", "\"B\""])
        XCTAssertTrue(written.contains("two"))
    }

    func testThereIsNothingToPostFromAnEmptySidecar() {
        XCTAssertNil(
            CanvasNotes.markdown(in: directory.appendingPathComponent("nothing.notes.md")))
        XCTAssertEqual(CanvasNotes.headings(in: ""), [])
    }

    /// The drawer renders the file natively, so the timestamp's `<sub>` wrapper would show
    /// up as literal angle brackets in the one surface built to make the sidecar legible.
    func testTheDrawerReadsTheTimestampAsAFootnoteRatherThanAsTags() throws {
        let canvas = directory.appendingPathComponent("plan.md")
        try CanvasNotes.append(
            CanvasAnnotation(anchor: .quote("a passage"), comment: "first"), for: canvas,
            at: stamp)

        let written = try XCTUnwrap(CanvasNotes.markdown(in: CanvasNotes.sidecarURL(for: canvas)))
        let footnote = try XCTUnwrap(
            written.split(separator: "\n").first { $0.hasPrefix("<sub>") })
        let time = footnote.dropFirst("<sub>".count).dropLast("</sub>".count)
        let readable = CanvasNotes.readable(written)

        XCTAssertFalse(readable.contains("<sub>"), "no tags in a natively rendered document")
        XCTAssertFalse(readable.contains("</sub>"))
        XCTAssertTrue(readable.contains("_\(time)_"), "the stamp itself survives, emphasised")
        XCTAssertTrue(
            readable.contains("## \"a passage\""),
            "and the heading is untouched — turning one back into a mark is #199's, and it "
                + "cannot do that against a sidecar the drawer has rewritten")
    }
}

/// The sidecar heading for a geometric mark (#112). The verb is the gesture, and the target
/// is what an agent greps for.
final class CanvasNotesMarkTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func heading(_ mark: CanvasAnnotation.Mark) -> String {
        let entry = CanvasNotes.entry(
            CanvasAnnotation(mark: mark, comment: "this shouldn't talk to that"), at: stamp)
        return entry.split(separator: "\n").first.map(String.init) ?? ""
    }

    func testACircleReadsAsCircled() {
        XCTAssertEqual(
            heading(.enclosure(covering: [.element(id: "phase-2", text: "Phase 2: Ship")])),
            "## circled `#phase-2` — \"Phase 2: Ship\"")
    }

    func testCirclingSeveralListsThemWithoutTheirLabels() {
        // A heading carrying three quoted labels is a paragraph, not a heading.
        XCTAssertEqual(
            heading(
                .enclosure(covering: [
                    .element(id: "phase-1", text: "One"), .element(id: "phase-2", text: "Two"),
                ])),
            "## circled `#phase-1`, `#phase-2`")
    }

    func testAnArrowReadsAsAnArrow() {
        XCTAssertEqual(
            heading(
                .relation(
                    from: .element(id: "phase-1", text: "One"),
                    to: .element(id: "phase-3", text: "Three"))),
            "## arrow `#phase-1` → `#phase-3`")
    }

    func testAnArrowIntoEmptySpaceSaysSo() {
        XCTAssertEqual(
            heading(.relation(from: .element(id: "phase-1", text: "One"), to: nil)),
            "## arrow `#phase-1` → (empty space)")
    }

    func testATapReadsAsPointedAt() {
        XCTAssertEqual(
            heading(.point(.element(id: "phase-2", text: "Phase 2"))),
            "## pointed at `#phase-2` — \"Phase 2\"")
    }

    func testASelectionIsUnchangedFromBeforeThisSlice() {
        XCTAssertEqual(
            heading(.selection(.element(id: "phase-2", text: "Phase 2"))),
            "## `#phase-2` — \"Phase 2\"")
        XCTAssertEqual(heading(.selection(.quote("the store move"))), "## \"the store move\"")
    }

    func testADegradedMarkStillReadsAsTheGesture() {
        // A mindmap node has no anchor, but the operator still circled something.
        XCTAssertEqual(
            heading(.enclosure(covering: [.quote("branchA")])), "## circled \"branchA\"")
    }
}
