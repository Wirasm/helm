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

    func testANoteBecomesAFileAPaneAndAnOpenEditor() throws {
        let model = mounted()

        let id = try XCTUnwrap(model.newNote(on: day("2026-08-07")))

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
                "\(WorkspaceStore.derivedKey(forRoot: WorkspaceStore.repositoryRoot(for: folder.path)))"
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
    func testANoteTakesTheKeyboardBecauseTheOperatorAskedForIt() throws {
        let model = mounted()

        let id = try XCTUnwrap(model.newNote())

        XCTAssertEqual(
            model.bench?.focusedPane?.id, id,
            "an agent's push appears without focus (#125); the operator's own note is the case "
                + "that is supposed to take it")
    }

    func testASecondNoteIsASecondPaneAndASecondFile() throws {
        let model = mounted()

        let first = try XCTUnwrap(model.newNote(on: day("2026-08-07")))
        let second = try XCTUnwrap(model.newNote(on: day("2026-08-07")))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            model.bench?.panes.filter { if case .canvas = $0.content { true } else { false } }
                .count, 2)
    }

    // MARK: - When it cannot

    /// A keystroke that silently does nothing is the failure shape `AGENTS.md` records paying for
    /// repeatedly. With no workspace there is no project whose store a note would belong to, and
    /// the operator is told which thing to do about it.
    func testWithNoWorkspaceOpenTheOperatorIsToldRatherThanNothingHappening() {
        let model = WorkbenchModel(terminals: TerminalManager(), artifactRoot: root)

        XCTAssertNil(model.newNote())

        XCTAssertEqual(model.noteFailure, OperatorNote.Failure.noWorkspace.sentence)
    }

    func testAnArtifactRootHelmCannotWriteIntoIsReportedOnTheBench() {
        let model = WorkbenchModel(
            terminals: TerminalManager(),
            artifactRoot: URL(fileURLWithPath: "/System/helm-should-not-write-here"))
        model.activate(workspacePath: workspace)

        XCTAssertNil(model.newNote())

        let failure = model.noteFailure ?? ""
        XCTAssertTrue(
            failure.hasPrefix("Could not start a note"),
            "the sentence has to name what failed, not merely that something did; got \"\(failure)\""
        )
    }

    /// **The control**: a failure must not leave the bench different from how it found it. It
    /// would pass by doing nothing at all, which is exactly what it is measuring — the two tests
    /// above are what stop "does nothing" being an acceptable answer overall.
    func testAFailedNoteAddsNoPane() {
        let model = WorkbenchModel(
            terminals: TerminalManager(),
            artifactRoot: URL(fileURLWithPath: "/System/helm-should-not-write-here"))
        model.activate(workspacePath: workspace)
        let before = model.bench?.panes.count

        _ = model.newNote()

        XCTAssertEqual(model.bench?.panes.count, before)
    }

    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)!.addingTimeInterval(12 * 3600)
    }
}
