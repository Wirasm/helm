import XCTest

@testable import Helm

/// Which files the canvas will let the operator write into (#289).
///
/// **These assertions replace `OperatorNoteTests`' recogniser half, and they say the opposite
/// thing on purpose.** That suite pinned *"an agent's plan is not a note, so it is not editable"* —
/// #307's scope line, drawn because the conflict question had no answer. It has one now
/// (`CanvasConflict`), and the operator has ruled that every markdown canvas is editable, so the
/// rule under test moved rather than the tests being dropped: what is left of the old rule is the
/// two exclusions below that still hold for reasons of their own.
final class EditableFileTests: XCTestCase {
    private func editable(_ path: String) -> EditableFile? {
        EditableFile(URL(fileURLWithPath: path))
    }

    // MARK: - What is editable

    func testEveryMarkdownExtensionTheCanvasRendersIsEditable() {
        XCTAssertNotNil(editable("/p/notes/2026-08-07-note.md"))
        XCTAssertNotNil(editable("/p/plans/feature.plan.md"))
        XCTAssertNotNil(editable("/p/research/finding.markdown"))
        XCTAssertNotNil(editable("/p/reviews/pr-311.mdown"))
    }

    /// **The widening, as one assertion.** Under #307 this file was read-only because of where it
    /// lived; nothing about where it lives is asked any more.
    func testAnAgentsArtifactIsEditableWhereverItLives() {
        XCTAssertNotNil(editable("/Users/x/.prp/helm-3ec376/plans/feature.plan.md"))
        XCTAssertNotNil(
            editable("/Users/x/Desktop/scratch.md"),
            "a file opened through Browse… from anywhere on disk is one he chose to open")
    }

    // MARK: - What is not

    /// An `.html` canvas is served to a `WKWebView` and the artifact's own JavaScript runs, so an
    /// editor there is a web app rather than a text view — the issue's own reasoning, and a
    /// different piece of work.
    func testAPageIsNotEditable() {
        XCTAssertNil(editable("/p/canvas/report.html"))
        XCTAssertNil(editable("/p/canvas/report.htm"))
    }

    /// Everything else the canvas shows is rendered monospaced rather than as a document, and the
    /// markdown source being *identical* to the file is what makes editing the identity operation.
    func testWhatHelmRendersAsPlainTextIsNotEditable() {
        XCTAssertNil(editable("/p/canvas/state.json"))
        XCTAssertNil(editable("/p/notes/screenshot.png"))
        XCTAssertNil(editable("/p/notes/dotless"))
    }

    /// **The one exclusion that survives the widening, and on its own merits.**
    /// `CanvasNotes.append` only ever appends, because the sidecar is the memory of every comment
    /// made on that canvas; the editor overwrites, so one keystroke in one would replace the lot.
    func testACanvassOwnSidecarIsNotEditable() {
        let plan = URL(fileURLWithPath: "/p/plans/feature.plan.md")

        XCTAssertNil(editable("/p/plans/feature.plan.notes.md"))
        // Derived from `CanvasNotes` rather than spelled again, so a change to the suffix is still
        // measured here instead of quietly passing.
        XCTAssertNil(
            EditableFile(CanvasNotes.sidecarURL(for: plan)),
            "and the pairing has to hold whatever CanvasNotes names its sidecars")
    }

    // MARK: - What is actually there

    /// **Three outcomes, and the middle one is the whole reason the type exists.** A bare
    /// `try? String(contentsOf:)` answers `nil` for both "nothing is there" and "there is
    /// something and I could not read it" — and those want opposite handling: the first is safe to
    /// write over, the second is the one case with no safe default.
    func testDiskContentsTellsAbsentFromUnreadable() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-disk-contents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(EditableFile(directory.appendingPathComponent("a.md")))

        XCTAssertEqual(file.diskContents(), .absent, "nothing there is not an unknown")

        try "# Plan\n".write(to: file.url, atomically: true, encoding: .utf8)
        XCTAssertEqual(file.diskContents(), .bytes("# Plan\n"))

        // The first two bytes of a three-byte UTF-8 sequence — what a read lands on while an agent
        // streams a long document, which is the very case `FileWatcher`'s debounce exists for.
        try Data([0x23, 0x20, 0xE2, 0x82]).write(to: file.url)
        XCTAssertEqual(
            file.diskContents(), .unreadable,
            "present and undecodable is its own answer, not the absent one")
    }

    // MARK: - Identity

    /// `Workbench.pane(showing:)` compares canvas sources by value, so two spellings of one path
    /// have to be one editable file for the same reason they are one pane (#88).
    func testAPathIsJudgedByWhereItResolvesRatherThanHowItIsSpelled() {
        XCTAssertEqual(
            editable("/p/./plans/../plans/a.md")?.path,
            editable("/p/plans/a.md")?.path)
    }
}
