import XCTest

@testable import Helm

/// Writing in a note: what the editor opens with, when helm saves, and every way it refuses to
/// lose what the operator typed (#289).
///
/// A real `CanvasModel` against a temporary artifact root — no window, no webview, no `~/.prp`.
@MainActor
final class NoteEditorTests: XCTestCase {
    private var root: URL!
    private var notes: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-note-editor-\(UUID().uuidString)")
        notes = root.appendingPathComponent("a-project-abcd1234/notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Anything a test made read-only has to be writable again or the whole tree survives.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notes.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// A canvas on `file`, with a debounce short enough that a test can wait for it.
    private func canvas(on file: URL, debounce: Duration = .milliseconds(20)) -> CanvasModel {
        CanvasModel(source: .file(file), artifactRoot: root, saveDebounce: debounce)
    }

    private func note(_ name: String = "2026-08-07-note.md", contents: String = "") throws -> URL {
        let file = notes.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - What may be written in at all

    /// **The scope line, from the pane's side.** An agent's artifact has no draft to reach and no
    /// button to reach it with, so the conflict question #289 leaves open is not one the operator
    /// can walk into.
    func testAnAgentsArtifactIsNotANoteAndTheWritingFaceIsUnreachable() throws {
        let plans = root.appendingPathComponent("a-project-abcd1234/plans")
        try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        let plan = plans.appendingPathComponent("feature.plan.md")
        try "# Plan".write(to: plan, atomically: true, encoding: .utf8)
        let model = canvas(on: plan)

        model.write()

        XCTAssertNil(model.note, "a plan in the store is an agent's, not the operator's")
        XCTAssertNil(model.draft, "and `write()` on one does nothing at all")
    }

    func testANoteOpensWithWhatIsOnDisk() throws {
        let model = canvas(on: try note(contents: "already written\n"))

        model.write()

        XCTAssertEqual(model.draft?.text, "already written\n")
        XCTAssertEqual(model.draft?.isDirty, false, "opening a file is not a change to it")
    }

    /// The other side of the read guard: a note whose file has been deleted under the operator is
    /// still a note, and helm opens it as empty rather than refusing to let him write.
    func testANoteWhoseFileIsGoneOpensEmpty() throws {
        let file = try note()
        try FileManager.default.removeItem(at: file)
        let model = canvas(on: file)

        model.write()

        XCTAssertEqual(model.draft?.text, "")
        XCTAssertNil(model.writeFailure)
    }

    /// **Seeding an empty draft over bytes helm could not read, then autosaving it, would delete
    /// them.** So it does not start.
    func testANoteHelmCannotReadIsNotOpenedForWriting() throws {
        let file = try note(contents: "somebody else's bytes")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        let model = canvas(on: file)

        model.write()

        XCTAssertNil(model.draft, "helm must not open an editor over bytes it has not read")
        XCTAssertNotNil(model.writeFailure, "and it must say so rather than looking like a no-op")
    }

    // MARK: - Saving

    func testTypingReachesTheFile() throws {
        let file = try note()
        let model = canvas(on: file)
        model.write()

        model.edit("a thought worth keeping")
        model.saveNote()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "a thought worth keeping")
        XCTAssertEqual(model.draft?.isDirty, false)
        XCTAssertNotNil(model.draft?.savedAt)
    }

    /// The debounce, driven for real: nothing but typing, and then a wait.
    func testTypingSavesItselfWithNoExplicitSave() async throws {
        let file = try note()
        let model = canvas(on: file, debounce: .milliseconds(20))
        model.write()

        model.edit("autosaved")
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "autosaved")
    }

    /// One write per pause, not one per keystroke — the same coalescing `FileWatcher` does from
    /// the other side of the same file.
    func testARunOfTypingIsOneSave() async throws {
        let file = try note()
        let model = canvas(on: file, debounce: .milliseconds(120))
        model.write()

        for text in ["a", "ab", "abc", "abcd"] { model.edit(text) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8), "",
            "nothing is written while the keys are still coming")

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "abcd")
    }

    /// **A failed save keeps every character and says why.** `saved` moves only on a write helm
    /// saw finish, so the draft stays dirty and the next keystroke tries again.
    func testAFailedSaveLosesNothingAndSaysWhy() throws {
        let file = try note()
        let model = canvas(on: file)
        model.write()
        model.edit("must not be lost")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: notes.path)

        model.saveNote()

        XCTAssertEqual(model.draft?.text, "must not be lost")
        XCTAssertEqual(model.draft?.isDirty, true, "still owed, so the next keystroke retries")
        XCTAssertNotNil(model.writeFailure)
    }

    /// The draft is the only copy of those keystrokes, so the Read button does not get to drop it
    /// on the strength of a write that failed.
    func testHelmWillNotLeaveTheEditorWhileThereIsTextItCouldNotWrite() throws {
        let file = try note()
        let model = canvas(on: file)
        model.write()
        model.edit("must not be lost")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: notes.path)

        model.read()

        XCTAssertEqual(model.draft?.text, "must not be lost")
    }

    func testReadingSavesFirstAndThenLeavesTheEditor() throws {
        let file = try note()
        let model = canvas(on: file)
        model.write()
        model.edit("written on the way out")

        model.read()

        XCTAssertNil(model.draft)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "written on the way out")
    }

    // MARK: - The flush points

    func testClosingThePaneSavesTheNote() throws {
        let file = try note()
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("half a sentence")

        model.close()

        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8), "half a sentence",
            "closing is the last moment a save can happen at all")
    }

    func testPointingTheCanvasAtAnotherFileSavesTheNoteItIsLeaving() throws {
        let file = try note()
        let other = try note("2026-08-08-note.md")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("belongs to the first file")

        model.open(other)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "belongs to the first file")
        XCTAssertNil(
            model.draft,
            "and the draft does not travel — the wrong text over the right path is the one way "
                + "an editor destroys work")
    }

    // MARK: - The watcher

    /// **helm's own save fires the file watcher**, which reloads the document — and a reload that
    /// re-seeded the draft would take away the sentence the operator is half way through.
    func testARefreshDoesNotTakeAwayWhatIsBeingTyped() throws {
        let file = try note(contents: "on disk")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("being typed right now")

        model.refresh()

        XCTAssertEqual(model.draft?.text, "being typed right now")
    }

    // MARK: - What the footer says

    func testTheStatusLineSaysWhetherTheFileIsBehindTheScreen() {
        var draft = NoteDraft(text: "typed", saved: "")
        XCTAssertEqual(draft.status, "Unsaved")

        draft.saved = "typed"
        draft.savedAt = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(draft.status.hasPrefix("Saved "), draft.status)

        XCTAssertEqual(
            NoteDraft(text: "", saved: "").status, "Empty note",
            "a note nothing has been typed into has not been saved and is not behind either")
    }
}
