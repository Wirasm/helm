import XCTest

@testable import Helm

/// Writing in a markdown canvas: what the editor opens with, when helm saves, every way it refuses
/// to lose what the operator typed, and what happens when somebody else writes the file too (#289).
///
/// A real `CanvasModel` against a temporary tree — no window, no webview, no `~/.prp`.
@MainActor
final class CanvasEditorTests: XCTestCase {
    private var root: URL!
    private var store: URL!
    private var notes: URL!
    private var plans: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-canvas-editor-\(UUID().uuidString)")
        store = root.appendingPathComponent("a-project-abcd1234")
        notes = store.appendingPathComponent("notes")
        plans = store.appendingPathComponent("plans")
        for directory in [notes!, plans!] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        // Anything a test made read-only has to be writable again or the whole tree survives.
        for directory in [notes!, plans!] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// A canvas on `file`, with a debounce short enough that a test can wait for it.
    private func canvas(on file: URL, debounce: Duration = .milliseconds(20)) -> CanvasModel {
        CanvasModel(source: .file(file), saveDebounce: debounce)
    }

    private func note(_ name: String = "2026-08-07-note.md", contents: String = "") throws -> URL {
        try write(contents, to: notes.appendingPathComponent(name))
    }

    private func plan(_ name: String = "feature.plan.md", contents: String = "") throws -> URL {
        try write(contents, to: plans.appendingPathComponent(name))
    }

    @discardableResult
    private func write(_ contents: String, to file: URL) throws -> URL {
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func contents(of file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: - What may be written in at all

    /// **The scope line, inverted, and that inversion is the ticket.** Until this change an agent's
    /// artifact had no draft to reach and no button to reach it with, because the conflict question
    /// had no answer. It has one now, so a plan is a file the operator can fix a sentence in — his
    /// own ruling, and the half of #289 that #307 deliberately left.
    func testAnAgentsPlanIsEditableAndTypingReachesTheFile() throws {
        let file = try plan(contents: "# Plan\n")
        let model = canvas(on: file)

        model.write()
        model.edit("# Plan\n\n- one more acceptance criterion\n")
        model.saveDraft()

        XCTAssertNotNil(model.editable, "every markdown canvas is editable now, not only notes/")
        XCTAssertEqual(try contents(of: file), "# Plan\n\n- one more acceptance criterion\n")
    }

    /// **An `.html` canvas is a page whose own scripts run, so an editor there is a web app.** The
    /// issue says so, and it is a different piece of work rather than a smaller one.
    func testAnHTMLArtifactIsNotEditable() throws {
        let file = try write("<h1>report</h1>", to: store.appendingPathComponent("report.html"))
        let model = canvas(on: file)

        model.write()

        XCTAssertNil(model.editable)
        XCTAssertNil(model.draft, "and `write()` on one does nothing at all")
    }

    /// Everything helm renders as monospaced text is still read-only: the widening is about the
    /// markdown canvas, which is the one surface whose source *is* the document.
    func testAFileHelmRendersAsPlainTextIsNotEditable() throws {
        let file = try write("{}", to: store.appendingPathComponent("state.json"))
        let model = canvas(on: file)

        model.write()

        XCTAssertNil(model.editable)
        XCTAssertNil(model.draft)
    }

    /// **A sidecar is markdown in the right place and is still not editable**, and the exclusion
    /// survives the widening on its own merits: `CanvasNotes.append` only ever appends, because
    /// the sidecar is the memory of every comment made on that canvas. One keystroke through an
    /// overwriting editor would replace the lot.
    func testACanvassOwnSidecarIsNotEditable() throws {
        let sidecar = try write(
            "## a comment\n", to: CanvasNotes.sidecarURL(for: try plan()))
        let model = canvas(on: sidecar)

        model.write()

        XCTAssertNil(model.editable)
        XCTAssertNil(model.draft)
    }

    func testAFileOpensWithWhatIsOnDisk() throws {
        let model = canvas(on: try note(contents: "already written\n"))

        model.write()

        XCTAssertEqual(model.draft?.text, "already written\n")
        XCTAssertEqual(model.draft?.isDirty, false, "opening a file is not a change to it")
    }

    /// The other side of the read guard: a file deleted under the operator is still editable, and
    /// helm opens it as empty rather than refusing to let him write.
    func testAFileThatIsGoneOpensEmpty() throws {
        let file = try note()
        try FileManager.default.removeItem(at: file)
        let model = canvas(on: file)

        model.write()

        XCTAssertEqual(model.draft?.text, "")
        XCTAssertNil(model.writeFailure)
    }

    /// **Seeding an empty draft over bytes helm could not read, then autosaving it, would delete
    /// them.** So it does not start.
    func testAFileHelmCannotReadIsNotOpenedForWriting() throws {
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
        model.saveDraft()

        XCTAssertEqual(try contents(of: file), "a thought worth keeping")
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

        XCTAssertEqual(try contents(of: file), "autosaved")
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
            try contents(of: file), "",
            "nothing is written while the keys are still coming")

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try contents(of: file), "abcd")
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

        model.saveDraft()

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
        XCTAssertEqual(try contents(of: file), "written on the way out")
    }

    // MARK: - The flush points

    func testClosingThePaneSavesTheDraft() throws {
        let file = try note()
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("half a sentence")

        model.close()

        XCTAssertEqual(
            try contents(of: file), "half a sentence",
            "closing is the last moment a save can happen at all")
    }

    func testPointingTheCanvasAtAnotherFileSavesTheOneItIsLeaving() throws {
        let file = try note()
        let other = try note("2026-08-08-note.md")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("belongs to the first file")

        model.open(other)

        XCTAssertEqual(try contents(of: file), "belongs to the first file")
        XCTAssertNil(
            model.draft,
            "and the draft does not travel — the wrong text over the right path is the one way "
                + "an editor destroys work")
    }

    // MARK: - The watcher, and helm's own writes

    /// **helm's own save fires the file watcher**, which reloads the document — and a reload that
    /// re-seeded the draft would take away the sentence the operator is half way through.
    ///
    /// **A control that has to pass either way, and it is the one that keeps the conflict rule
    /// honest**: a `reconcile` that raised a conflict on every refresh would satisfy every
    /// clobber assertion below and make autosave unusable. What tells the two apart is
    /// `draft.saved`, and this is the case where it matches.
    func testARefreshDoesNotTakeAwayWhatIsBeingTyped() throws {
        let file = try note(contents: "on disk")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("being typed right now")

        model.refresh()

        XCTAssertEqual(model.draft?.text, "being typed right now")
        XCTAssertNil(model.draft?.conflict, "helm's own file, unchanged, is not a second writer")
    }

    /// The same control one step further along: after a real save the bytes on disk are helm's
    /// own, so the watcher firing on them must be silent too.
    func testHelmsOwnSaveIsNotAConflict() throws {
        let file = try note(contents: "before")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("after")
        model.saveDraft()

        model.refresh()

        XCTAssertNil(model.draft?.conflict)
        XCTAssertNil(model.conflictNotice)
        XCTAssertEqual(model.draft?.text, "after")
    }

    // MARK: - When somebody else writes it too

    /// **Nothing of the operator's to lose, so nothing is asked of him.** This is the ordinary
    /// case: the editor is open on a plan, he has typed nothing since it last saved, and the agent
    /// rewrites it. He sees the new text.
    func testARewriteUnderACleanDraftIsAdoptedSilently() throws {
        let file = try plan(contents: "# Plan\n")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()

        try write("# Plan\n\n## Phase 2\n", to: file)
        model.refresh()

        XCTAssertEqual(model.draft?.text, "# Plan\n\n## Phase 2\n")
        XCTAssertEqual(model.draft?.isDirty, false, "and it is not now pending a write back")
        XCTAssertNil(model.draft?.conflict, "there was nothing to conflict with")
        XCTAssertNil(model.conflictNotice)
    }

    /// **The clobber, refused.** This is the failure the whole ticket is arranged around: the
    /// operator has unsaved text, an agent rewrites the file, and the next autosave would put his
    /// buffer straight over it with nothing anywhere saying so.
    func testARewriteUnderUnsavedTextStopsHelmSaving() throws {
        let file = try plan(contents: "# Plan\n")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("# Plan\n\n- mine\n")

        try write("# Plan\n\n## Rewritten by the agent\n", to: file)
        model.refresh()
        model.saveDraft()

        XCTAssertEqual(
            try contents(of: file), "# Plan\n\n## Rewritten by the agent\n",
            "helm must not write over bytes it has not shown the operator")
        XCTAssertEqual(
            model.draft?.text, "# Plan\n\n- mine\n",
            "and it must not throw away his either — both directions, or it is not an answer")
        XCTAssertNotNil(model.draft?.conflict)
    }

    /// **The watcher's lag, which is where the guarantee would otherwise only be probable.**
    ///
    /// `FileWatcher` debounces 120ms, so a write landing inside the 120ms before an autosave fires
    /// reaches the model *after* helm has already saved — and the reconcile that follows compares
    /// the file against helm's own bytes and finds them equal. Silent, and the exact failure this
    /// design exists to prevent. Driven here by writing the file and saving with **no `refresh()`
    /// in between**, which is that ordering exactly: the save has to read for itself.
    func testASaveThatBeatsTheWatcherStillDoesNotClobber() throws {
        let file = try plan(contents: "# Plan\n")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("mine")

        try write("theirs, and the watcher has not fired yet", to: file)
        model.saveDraft()

        XCTAssertEqual(try contents(of: file), "theirs, and the watcher has not fired yet")
        XCTAssertNotNil(model.draft?.conflict, "and he is told, rather than it merely not saving")
        XCTAssertEqual(model.draft?.text, "mine")
    }

    /// A refusal nobody can see is the silence this repository has paid for repeatedly. The strip
    /// names the file and says what helm has stopped doing.
    func testTheOperatorIsToldRatherThanTheSaveJustNotHappening() throws {
        let file = try plan(contents: "# Plan\n")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("mine")

        try write("theirs", to: file)
        model.refresh()

        let notice = try XCTUnwrap(model.conflictNotice)
        XCTAssertTrue(notice.contains("feature.plan.md"), notice)
        XCTAssertTrue(notice.contains("stopped saving"), notice)
        XCTAssertEqual(model.draft?.status, "Not saving", "and the footer does not say `Unsaved`")
    }

    /// **Keep mine**: the operator, having been told, chooses to replace what is there.
    func testKeepMineWritesTheBufferOverTheirVersion() throws {
        let file = try plan(contents: "# Plan\n")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("mine")
        try write("theirs", to: file)
        model.refresh()

        model.keepMine()

        XCTAssertEqual(try contents(of: file), "mine")
        XCTAssertNil(model.draft?.conflict, "resolved, so autosave is running again")
        XCTAssertEqual(model.draft?.isDirty, false)
    }

    /// **Keep mine is about the version he was shown, so a newer one stops it too.** He pressed a
    /// button meaning "replace what you told me about"; replacing something else instead is the
    /// same silent overwrite one turn later.
    func testKeepMineIsRefusedAgainWhenAThirdVersionArrivedFirst() throws {
        let file = try plan(contents: "# Plan\n")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("mine")
        try write("the version he was shown", to: file)
        model.refresh()

        try write("a third version nobody has seen", to: file)
        model.keepMine()

        XCTAssertEqual(try contents(of: file), "a third version nobody has seen")
        XCTAssertEqual(
            model.draft?.conflict, CanvasConflict(theirs: "a third version nobody has seen"),
            "told again, about the newer bytes")
        XCTAssertEqual(model.draft?.text, "mine")
    }

    /// **Take theirs adopts the version the operator was SHOWN, not whatever is on disk when he
    /// clicks.** That is the whole reason `CanvasConflict` holds the bytes: a third write landing
    /// between the strip going up and the button being pressed must not be adopted silently, and
    /// re-reading the file at the click is exactly how that would happen.
    func testTakeTheirsAdoptsTheVersionTheStripWasAbout() throws {
        let file = try plan(contents: "# Plan\n")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("mine")
        try write("the version he was shown", to: file)
        model.refresh()

        try write("a third version nobody has seen", to: file)
        model.takeTheirs()

        XCTAssertEqual(model.draft?.text, "the version he was shown")
        XCTAssertNil(model.draft?.conflict)
    }

    /// The buffer is his until he says otherwise — and while a conflict is up, Read is not that.
    /// It refuses for the reason a failed write refuses: `saveDraft` did not write, so the draft
    /// is still dirty, and dropping it would be the data loss this design is arranged around.
    func testHelmWillNotLeaveTheEditorWhileAConflictIsUnresolved() throws {
        let file = try plan(contents: "# Plan\n")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("mine")
        try write("theirs", to: file)
        model.refresh()

        model.read()

        XCTAssertEqual(model.draft?.text, "mine")
        XCTAssertNotNil(model.draft?.conflict)
    }

    /// A second write while the strip is up replaces what it is about, so the operator always
    /// chooses between his text and the newest bytes helm has actually seen.
    func testASecondRewriteReplacesWhatTheStripIsAbout() throws {
        let file = try plan(contents: "# Plan\n")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("mine")
        try write("first rewrite", to: file)
        model.refresh()

        try write("second rewrite", to: file)
        model.refresh()
        model.takeTheirs()

        XCTAssertEqual(model.draft?.text, "second rewrite")
    }

    /// **A deletion is not content to preserve.** The file loads as a notice rather than markdown,
    /// the draft is left exactly where it is, and the next save recreates the file — the same
    /// answer `write()` gives for a file that was already absent.
    func testAFileDeletedUnderADraftIsNotAConflict() throws {
        let file = try note(contents: "on disk")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("still being typed")

        try FileManager.default.removeItem(at: file)
        model.refresh()
        model.saveDraft()

        XCTAssertNil(model.draft?.conflict)
        XCTAssertEqual(try contents(of: file), "still being typed")
    }

    /// Whoever wrote the file put helm's own bytes back, so there is nothing left to refuse and
    /// the strip does not stay up over a file helm agrees with again.
    func testAConflictClearsWhenTheDiskAgreesWithHelmAgain() throws {
        let file = try plan(contents: "# Plan\n")
        let model = canvas(on: file, debounce: .seconds(30))
        model.write()
        model.edit("mine")
        try write("theirs", to: file)
        model.refresh()

        try write("# Plan\n", to: file)
        model.refresh()

        XCTAssertNil(model.draft?.conflict)
        XCTAssertEqual(model.draft?.text, "mine", "and his text is still his")
    }

    // MARK: - What the footer says

    func testTheStatusLineSaysWhetherTheFileIsBehindTheScreen() {
        var draft = CanvasDraft(text: "typed", saved: "")
        XCTAssertEqual(draft.status, "Unsaved")

        draft.saved = "typed"
        draft.savedAt = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(draft.status.hasPrefix("Saved "), draft.status)

        XCTAssertEqual(
            CanvasDraft(text: "", saved: "").status, "No changes",
            "a file nothing has been typed into has not been saved and is not behind either")

        draft.conflict = CanvasConflict(theirs: "somebody else's")
        XCTAssertEqual(
            draft.status, "Not saving",
            "`Unsaved` promises helm is about to write; it has stopped, and saying otherwise is "
                + "the reassurance that loses the work")
    }
}
