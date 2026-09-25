import XCTest

@testable import Helm

/// A sidecar written while its canvas is open reaches the pane (#251).
///
/// **Every change here is a real file write, never a call to `refreshNotes()`.** This is a join —
/// the file on disk on one side, the Notes button on the other — and calling the refresh directly
/// is how #216's suites passed while nothing crossed it. So each test writes the way an agent
/// does and then waits for the model to notice on its own.
///
/// **Every wait here lets a window elapse, never races one.** The polls stop as soon as the
/// condition holds and give up after seconds, so a slow machine only makes them slower; the two
/// negative checks sleep well past the watcher's 120ms debounce, and an overshoot there only
/// gives a wrong refresh more time to show itself.
@MainActor
final class CanvasSidecarWatchTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var sidecar: URL { CanvasNotes.sidecarURL(for: file) }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-sidecar-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("plan.md")
        try "# plan".write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// **The bug as filed**: no sidecar when the canvas opened, an agent writes one, and the
    /// Notes button has to appear without the canvas being reopened.
    func testASidecarCreatedWhileTheCanvasIsOpenMakesTheNotesButtonAppear() async throws {
        let model = CanvasModel()
        model.open(file)
        XCTAssertFalse(model.hasNotes, "precondition: nothing beside the canvas yet")

        try "## from the agent\n\nread this\n".write(
            to: sidecar, atomically: true, encoding: .utf8)

        let appeared = await eventually { model.hasNotes }
        XCTAssertTrue(
            appeared,
            "an agent's notes written beside an open canvas never reached the pane — the drawer "
                + "built to show them is unreachable until the canvas is reopened")
        XCTAssertEqual(model.notes, ["from the agent"])
    }

    /// The same, written the way `>` in a shell writes: created in place, not renamed into
    /// place. Creation still changes the directory, so this is the directory watch's case.
    func testASidecarCreatedInPlaceIsSeenToo() async throws {
        let model = CanvasModel()
        model.open(file)

        FileManager.default.createFile(atPath: sidecar.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sidecar)
        try handle.write(contentsOf: Data("## streamed\n\nin place\n".utf8))
        try handle.close()

        let appeared = await eventually { model.notesText?.contains("in place") == true }
        XCTAssertTrue(appeared, "a sidecar that was never renamed into place is still a sidecar")
    }

    /// **Gaining content**: an append to a sidecar that already existed changes no directory
    /// entry, so only a watch on the file itself sees it. This is what `>>` and
    /// `CanvasNotes.append` both do.
    func testAnAppendToAnExistingSidecarUpdatesTheNotes() async throws {
        try "## first\n\none\n".write(to: sidecar, atomically: true, encoding: .utf8)
        let model = CanvasModel()
        model.open(file)
        XCTAssertEqual(model.notes, ["first"], "precondition")

        let handle = try FileHandle(forWritingTo: sidecar)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n## second\n\ntwo\n".utf8))
        try handle.close()

        let grew = await eventually { model.notes == ["first", "second"] }
        XCTAssertTrue(grew, "the count and the drawer must follow the file, not the open")
    }

    /// A sidecar created **after** the canvas opened and then appended to: the file watch has
    /// to be armed when the file appears, not only at open, or the second write is lost.
    func testASidecarCreatedLaterIsStillWatchedForAppends() async throws {
        let model = CanvasModel()
        model.open(file)

        try "## first\n\none\n".write(to: sidecar, atomically: true, encoding: .utf8)
        let created = await eventually { model.notes == ["first"] }
        XCTAssertTrue(created, "precondition")

        let handle = try FileHandle(forWritingTo: sidecar)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n## second\n\ntwo\n".utf8))
        try handle.close()

        let grew = await eventually { model.notes == ["first", "second"] }
        XCTAssertTrue(grew, "a sidecar that did not exist at open is watched once it does")
    }

    /// **Emptied or removed**: the button must not persist over nothing.
    func testASidecarEmptiedInPlaceTakesTheButtonAway() async throws {
        try "## first\n\none\n".write(to: sidecar, atomically: true, encoding: .utf8)
        let model = CanvasModel()
        model.open(file)
        XCTAssertTrue(model.hasNotes, "precondition")

        let handle = try FileHandle(forWritingTo: sidecar)
        try handle.truncate(atOffset: 0)
        try handle.close()

        let gone = await eventually { !model.hasNotes }
        XCTAssertTrue(gone, "an empty sidecar has nothing behind the button")
    }

    func testASidecarRemovedTakesTheButtonAway() async throws {
        try "## first\n\none\n".write(to: sidecar, atomically: true, encoding: .utf8)
        let model = CanvasModel()
        model.open(file)
        XCTAssertTrue(model.hasNotes, "precondition")

        try FileManager.default.removeItem(at: sidecar)

        let gone = await eventually { !model.hasNotes }
        XCTAssertTrue(gone, "a button over a deleted file opens a drawer on nothing")
    }

    /// **The sidecar watch never reloads the artifact.** Watching two files must not turn a
    /// note into a re-render of the page under the operator — the generation is what every
    /// canvas view keys its reload on.
    ///
    /// Passes before the fix as well, trivially, because nothing watched the sidecar at all; it
    /// is here to fail if the fix overshoots by routing the sidecar through `refresh()`.
    func testASidecarWriteDoesNotReloadTheCanvas() async throws {
        let model = CanvasModel()
        model.open(file)
        let before = try generation(of: model)

        try "## note\n\nhi\n".write(to: sidecar, atomically: true, encoding: .utf8)
        _ = await eventually { model.hasNotes }
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(try generation(of: model), before, "a note is not an edit to the artifact")
    }

    /// **The watch ends with the document**, the lifetime `open(_:)` already gives the canvas
    /// watcher. The previous artifact's sidecar being written must not put its notes on the
    /// artifact that replaced it.
    ///
    /// Also passes before the fix, trivially — it fails only if the sidecar watch outlives the
    /// document it was about.
    func testAnotherArtifactsSidecarDoesNotReachThePaneAfterItMovesOn() async throws {
        let model = CanvasModel()
        model.open(file)
        let other = directory.appendingPathComponent("tasks.md")
        try "# tasks".write(to: other, atomically: true, encoding: .utf8)
        model.open(other)

        try "## stale\n\nabout plan.md\n".write(to: sidecar, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(model.hasNotes, "tasks.md has no notes; plan.md's are not its")
    }

    // MARK: - Helpers

    private func generation(of model: CanvasModel) throws -> Int {
        guard let document = model.showing else {
            throw XCTSkip("the canvas is not showing a file")
        }
        return document.generation
    }

    /// Poll until `condition` holds or `timeout` passes. Returns whether it held.
    private func eventually(
        timeout: Duration = .seconds(5), _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}
