import AppKit
import HelmWire
import XCTest

@testable import Helm

/// ⌘⇧N end to end on the bench: the file, the pane, the keyboard, and what happens when helm
/// cannot make one (#289).
///
/// A real `WorkbenchModel` against a toy benchd (`ToyBench`), an isolated `TerminalManager` and a
/// **temporary artifact root** — nothing here can reach the operator's own `~/.prp`.
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

    private var rig: ToyRig?

    /// helm with `workspace` open, or nothing open when `open` is false.
    private func mounted(
        open: Bool = true, artifactRoot: URL? = nil,
        resolveRepository: (@Sendable (String) async throws -> String)? = nil
    ) throws -> WorkbenchModel {
        let root = artifactRoot ?? self.root!
        let document =
            open
            ? BenchDocument(
                workspaces: [
                    .init(path: workspace.value, bench: ToyBench.bench([ToyBench.terminal()]))
                ], active: workspace.value)
            : BenchDocument(workspaces: [], active: nil)
        let rig = try toyRig(document: document) { terminals, client in
            if let resolveRepository {
                WorkbenchModel(
                    terminals: terminals, agents: .blind, artifactRoot: root,
                    resolveRepository: resolveRepository, client: client)
            } else {
                WorkbenchModel(
                    terminals: terminals, agents: .blind, artifactRoot: root, client: client)
            }
        }
        self.rig = rig
        return rig.model
    }

    /// Closing the last workspace, as the operator does it.
    private func closeTheWorkspace(_ model: WorkbenchModel) {
        model.send(.workspaceClose(path: workspace.value), by: .operatorGesture)
    }

    // MARK: - What ⌘⇧N does

    func testANoteBecomesAFileAPaneAndAnOpenEditor() async throws {
        let model = try mounted()

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
    /// mean something. An agent's push is an agent's verb and appears without focus (#125); the
    /// operator pressed a key and expects to type, so the note is his `pane/open`.
    func testANoteIsTheOperatorsOpen() async throws {
        let model = try mounted()

        _ = try await note(model)

        let sent = try XCTUnwrap(rig?.server.verbs.last)
        XCTAssertEqual(sent["verb"] as? String, "pane/open")
        XCTAssertEqual(
            (sent["by"] as? [String: Any])?["kind"] as? String, "operator",
            "the operator's own note is the case that is supposed to take the keyboard")
    }

    func testASecondNoteIsASecondPaneAndASecondFile() async throws {
        let model = try mounted()

        let first = try await note(model, on: day("2026-08-07"))
        let second = try await note(model, on: day("2026-08-07"))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            model.bench?.panes.filter { if case .canvas = $0.content { true } else { false } }
                .count, 2)
    }

    /// **Closing the workspace lets the canvases go**, through the canvas kind's `close()` as each
    /// pane leaves the document. It is a teardown that would take a note being typed with it if
    /// nothing saved first: a pending save holds its model weakly, so the model deallocs and the
    /// keystrokes since the last write are gone.
    func testClosingTheLastWorkspaceSavesANoteBeingTyped() async throws {
        let model = try mounted()
        let id = try await note(model, on: day("2026-08-07"))
        let pane = try XCTUnwrap(model.bench?.pane(id))
        guard case let .canvas(.file(path)) = pane.content else {
            return XCTFail("a note is a canvas pane pointed at its own file")
        }
        model.canvas(for: pane).edit("typed, and then the workspace went away")

        closeTheWorkspace(model)

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
        let model = try mounted()
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
    /// the debounce race was the only thing it could lose.** A closing pane saves through
    /// `saveDraft` (the canvas kind's `close`), which refuses while a conflict is up, so closing
    /// the workspace with the strip on screen drops that buffer exactly as closing the pane and
    /// quitting do.
    ///
    /// One test per exit: it was claimed in three comments and checked in one.
    func testClosingTheLastWorkspaceWithAnUnresolvedConflictKeepsTheFile() async throws {
        let model = try mounted()
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

        closeTheWorkspace(model)

        XCTAssertEqual(
            try String(contentsOfFile: path.value, encoding: .utf8),
            "somebody else got here first",
            "closing the workspace must not become a way a conflict gets decided by a write")
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
        let model = try mounted()
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
    func testWithNoWorkspaceOpenTheOperatorIsToldRatherThanNothingHappening() async throws {
        let model = try mounted(open: false)

        let id = await model.newNote()
        XCTAssertNil(id)

        XCTAssertEqual(model.noteFailure, OperatorNote.Failure.noWorkspace.sentence)
    }

    func testAnArtifactRootHelmCannotWriteIntoIsReportedOnTheBench() async throws {
        let model = try mounted(
            artifactRoot: URL(fileURLWithPath: "/System/helm-should-not-write-here"))

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
    func testAGitThatDoesNotAnswerIsReportedAndWritesNothing() async throws {
        let model = try mounted(resolveRepository: { _ in throw Subprocess.Failure.timedOut })
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
        let model = try mounted(resolveRepository: { path in
            enteredSignal.yield()
            for await _ in release { break }
            return WorkspaceStore.resolved(path)
        })
        let other = folder.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let pending = Task { await model.newNote() }
        for await _ in entered { break }
        model.send(.workspaceOpen(path: other.path), by: .operatorGesture)
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
    func testAFailedNoteAddsNoPane() async throws {
        let model = try mounted(
            artifactRoot: URL(fileURLWithPath: "/System/helm-should-not-write-here"))
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
