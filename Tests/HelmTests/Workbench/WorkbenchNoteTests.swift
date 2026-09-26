import AppKit
import XCTest

@testable import Helm

/// ⌘⇧N end to end on the bench: the file, the pane, the keyboard, and what happens when helm
/// cannot make one (#289).
///
/// A real `WorkbenchModel` against an isolated `TerminalManager` and a **temporary artifact
/// root** — nothing here can reach the operator's own `~/.prp`.
@MainActor
final class WorkbenchNoteTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var workspace: WorkspacePath!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-workbench-note-\(UUID().uuidString)")
        root = base.appendingPathComponent("prp")
        folder = base.appendingPathComponent("a-project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        workspace = WorkspacePath(folder.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func mounted() -> WorkbenchModel {
        let model = WorkbenchModel(terminals: TerminalManager(), artifactRoot: root)
        model.activate(workspacePath: workspace)
        return model
    }

    // MARK: - What ⌘⇧N does

    func testANoteBecomesAFileAPaneAndAnOpenEditor() async throws {
        let model = mounted()

        let id = try await note(model, on: day("2026-08-07"))

        let pane = try XCTUnwrap(model.bench?.pane(id))
        guard case let .canvas(.file(path)) = pane.content else {
            return XCTFail("a note is a canvas pane pointed at its own file")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path.value),
            "the file exists before the pane does — a canvas on nothing is a notice, not a note")
        XCTAssertEqual(
            path.value,
            root.appendingPathComponent(
                "\(WorkspaceStore.derivedKey(forRoot: WorkspaceStore.resolved(folder.path)))"
                    + "/notes/2026-08-07-note.md"
            ).path)
        XCTAssertNotNil(
            model.canvas(for: pane).draft,
            "⌘⇧N opens straight into the writing face — a rendered view of an empty file is a "
                + "blank pane with a button on it")
    }

    /// **This one seizes, deliberately** — and it is the contrast that makes the spool's refusal
    /// mean something. `Workbench.offer` exists for what nobody asked for; the operator pressed a
    /// key and expects to type.
    func testANoteTakesTheKeyboardBecauseTheOperatorAskedForIt() async throws {
        let model = mounted()

        let id = try await note(model)

        XCTAssertEqual(
            model.bench?.focusedPane?.id, id,
            "an agent's push appears without focus (#125); the operator's own note is the case "
                + "that is supposed to take it")
    }

    func testASecondNoteIsASecondPaneAndASecondFile() async throws {
        let model = mounted()

        let first = try await note(model, on: day("2026-08-07"))
        let second = try await note(model, on: day("2026-08-07"))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            model.bench?.panes.filter { if case .canvas = $0.content { true } else { false } }
                .count, 2)
    }

    /// **`deactivate` lets the canvases go**, through the canvas kind's `close()` since PR 3a of
    /// #354 (it used to drop them unclosed after a separate flush). Either way it is a teardown
    /// that would take a note being typed with it if nothing saved first: a pending save holds its
    /// model weakly, so the model deallocs and the keystrokes since the last write are gone.
    func testClosingTheLastWorkspaceSavesANoteBeingTyped() async throws {
        let model = mounted()
        let id = try await note(model, on: day("2026-08-07"))
        let pane = try XCTUnwrap(model.bench?.pane(id))
        guard case let .canvas(.file(path)) = pane.content else {
            return XCTFail("a note is a canvas pane pointed at its own file")
        }
        model.canvas(for: pane).edit("typed, and then the workspace went away")

        model.deactivate()

        XCTAssertEqual(
            try String(contentsOfFile: path.value, encoding: .utf8),
            "typed, and then the workspace went away")
    }

    /// **⌘Q is the ordinary way to leave, and it reached no flush point at all.**
    ///
    /// The failure it caused is not a bounded one: `edit` reschedules the debounce on every
    /// keystroke, so a note typed in one burst with no pause in it has never been written once,
    /// and quitting there lost the whole note. Posted here as the notification rather than
    /// simulated, so what is measured is the subscription — the thing that was missing.
    func testQuittingWritesANoteThatHasNeverBeenSavedEvenOnce() async throws {
        let model = mounted()
        let id = try await note(model, on: day("2026-08-07"))
        let pane = try XCTUnwrap(model.bench?.pane(id))
        guard case let .canvas(.file(path)) = pane.content else {
            return XCTFail("a note is a canvas pane pointed at its own file")
        }
        // No pause anywhere in it, which is the case the debounce alone never covers.
        model.canvas(for: pane).edit("typed in one burst, then ⌘Q")

        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification, object: NSApplication.shared)

        XCTAssertEqual(
            try String(contentsOfFile: path.value, encoding: .utf8),
            "typed in one burst, then ⌘Q",
            "the subscription has to be synchronous — a hop to the main queue is a save that "
                + "never runs, because the run loop is stopping")
    }

    /// **The third exit that takes the same position, and the one whose own comment used to say
    /// the debounce race was the only thing it could lose.** `deactivate` saves through
    /// `saveDraft` (the canvas kind's `close`), which refuses while a conflict is up, so switching workspace with the strip on
    /// screen drops that buffer exactly as closing the pane and quitting do.
    ///
    /// One test per exit: it was claimed in three comments and checked in one.
    func testClosingTheLastWorkspaceWithAnUnresolvedConflictKeepsTheFile() async throws {
        let model = mounted()
        let id = try await note(model, on: day("2026-08-07"))
        let pane = try XCTUnwrap(model.bench?.pane(id))
        guard case let .canvas(.file(path)) = pane.content else {
            return XCTFail("a note is a canvas pane pointed at its own file")
        }
        let canvas = model.canvas(for: pane)
        canvas.edit("typed, and never resolved")
        try "somebody else got here first".write(
            toFile: path.value, atomically: true, encoding: .utf8)
        canvas.refresh()
        XCTAssertNotNil(canvas.draft?.conflict, "the arrangement is the conflict, so it must exist")

        model.deactivate()

        XCTAssertEqual(
            try String(contentsOfFile: path.value, encoding: .utf8),
            "somebody else got here first",
            "switching workspace must not become a way a conflict gets decided by a write")
    }

    /// **The cost of the conflict guard at the one exit that cannot ask, stated as a test rather
    /// than discovered later** (#289). ⌘Q flushes every open draft through `saveDraft`, which
    /// refuses while somebody else's bytes are on disk — so the buffer goes with the process.
    ///
    /// That is the decision and not an oversight. The alternative, treating quit as an implicit
    /// *keep mine*, would write what is usually a sentence over what is usually a whole rewrite,
    /// at the moment nobody can be asked which. helm keeps the copy another process can reproduce
    /// and loses the one it cannot, with the strip having said so since the conflict appeared.
    ///
    /// Posted as the real notification, like the test above it, so what is measured is the
    /// subscription rather than a simulation of it.
    func testQuittingWithAnUnresolvedConflictKeepsTheFileAndLosesTheBuffer() async throws {
        let model = mounted()
        let id = try await note(model, on: day("2026-08-07"))
        let pane = try XCTUnwrap(model.bench?.pane(id))
        guard case let .canvas(.file(path)) = pane.content else {
            return XCTFail("a note is a canvas pane pointed at its own file")
        }
        let canvas = model.canvas(for: pane)
        canvas.edit("typed, and never resolved")
        try "somebody else got here first".write(
            toFile: path.value, atomically: true, encoding: .utf8)
        canvas.refresh()
        XCTAssertNotNil(canvas.draft?.conflict, "the arrangement is the conflict, so it must exist")

        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification, object: NSApplication.shared)

        XCTAssertEqual(
            try String(contentsOfFile: path.value, encoding: .utf8),
            "somebody else got here first",
            "quitting must not become the third way a conflict gets decided by a write")
    }

    // MARK: - When it cannot

    /// A keystroke that silently does nothing is the failure shape `AGENTS.md` records paying for
    /// repeatedly. With no workspace there is no project whose store a note would belong to, and
    /// the operator is told which thing to do about it.
    func testWithNoWorkspaceOpenTheOperatorIsToldRatherThanNothingHappening() async {
        let model = WorkbenchModel(terminals: TerminalManager(), artifactRoot: root)

        let id = await model.newNote()
        XCTAssertNil(id)

        XCTAssertEqual(model.noteFailure, OperatorNote.Failure.noWorkspace.sentence)
    }

    func testAnArtifactRootHelmCannotWriteIntoIsReportedOnTheBench() async {
        let model = WorkbenchModel(
            terminals: TerminalManager(),
            artifactRoot: URL(fileURLWithPath: "/System/helm-should-not-write-here"))
        model.activate(workspacePath: workspace)

        let id = await model.newNote()
        XCTAssertNil(id)

        let failure = model.noteFailure ?? ""
        XCTAssertTrue(
            failure.hasPrefix("Could not start a note"),
            "the sentence has to name what failed, not merely that something did; got \"\(failure)\""
        )
    }

    /// **A git that does not answer is a sentence, not a frozen window or a note in the wrong
    /// store** (#390). The resolver throws what `Subprocess` throws at its deadline.
    func testAGitThatDoesNotAnswerIsReportedAndWritesNothing() async {
        let model = WorkbenchModel(
            terminals: TerminalManager(), artifactRoot: root,
            resolveRepository: { _ in throw Subprocess.Failure.timedOut })
        model.activate(workspacePath: workspace)
        let before = model.bench?.panes.count

        let id = await model.newNote()

        XCTAssertNil(id)
        XCTAssertEqual(
            model.noteFailure,
            OperatorNote.Failure.repositoryUnresolved(workspace.value).sentence)
        XCTAssertEqual(model.bench?.panes.count, before)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path), [],
            "no store is registered for a repository nobody could name")
    }

    /// The window stays live while git runs, so the operator can switch workspace before it
    /// answers. The note belonged to the workspace he pressed ⌘⇧N in; opening it on the new
    /// one's bench would be the wrong place, so nothing is created at all.
    func testSwitchingWorkspaceWhileGitRunsStartsNoNote() async throws {
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let model = WorkbenchModel(
            terminals: TerminalManager(), artifactRoot: root,
            resolveRepository: { path in
                enteredSignal.yield()
                for await _ in release { break }
                return WorkspaceStore.resolved(path)
            })
        model.activate(workspacePath: workspace)
        let other = folder.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let pending = Task { await model.newNote() }
        for await _ in entered { break }
        model.activate(workspacePath: WorkspacePath(other.path))
        releaseSignal.yield()
        let id = await pending.value

        XCTAssertNil(id)
        XCTAssertEqual(
            model.bench?.panes.filter { if case .canvas = $0.content { true } else { false } }
                .count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    /// **The control**: a failure must not leave the bench different from how it found it. It
    /// would pass by doing nothing at all, which is exactly what it is measuring — the two tests
    /// above are what stop "does nothing" being an acceptable answer overall.
    func testAFailedNoteAddsNoPane() async {
        let model = WorkbenchModel(
            terminals: TerminalManager(),
            artifactRoot: URL(fileURLWithPath: "/System/helm-should-not-write-here"))
        model.activate(workspacePath: workspace)
        let before = model.bench?.panes.count

        _ = await model.newNote()

        XCTAssertEqual(model.bench?.panes.count, before)
    }

    /// `newNote`, required to have made one. `XCTUnwrap`'s autoclosure cannot `await`.
    private func note(_ model: WorkbenchModel, on date: Date = Date()) async throws -> Pane.ID {
        let id = await model.newNote(on: date)
        return try XCTUnwrap(id)
    }

    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)!.addingTimeInterval(12 * 3600)
    }
}
