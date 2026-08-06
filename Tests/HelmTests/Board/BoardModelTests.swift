import XCTest

@testable import Helm

/// The board's wiring: fixture registry → decode → rollup → published map, and the
/// poll loop's lifetime.
///
/// The pid *match* cannot be exercised here — no pty spawns under a shielded
/// display, so `foregroundPid` never returns an agent. Everything either side of
/// the match can be, and is.
///
/// Isolation sits on the test methods rather than the class: `setUpWithError` and
/// `tearDownWithError` override nonisolated XCTest API, so a `@MainActor` class
/// cannot own a mutable fixture without the compiler rightly complaining.
final class BoardModelTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-board-workspace")
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-board-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func writeRow(pid: Int, status: String) throws {
        try #"{"pid":\#(pid),"cwd":"\#(workspace.value)","status":"\#(status)"}"#
            .write(
                to: root.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
    }

    @MainActor
    func testTerminalWithNoSurfaceYetContributesNoMark() async throws {
        // A workspace helm hosts, an agent row that names its cwd — and still no
        // mark, because the surface has no process for the row's pid to match.
        // cwd is not the attribution; the pid is.
        try writeRow(pid: 9139, status: "idle")
        let manager = TerminalManager()
        manager.activate(workspacePath: workspace)
        XCTAssertEqual(manager.sessions(for: workspace).count, 1, "the fixture needs a terminal")

        let board = BoardModel(manager: manager, root: root)
        await board.refresh()

        XCTAssertNil(
            board.presence[workspace.value],
            "an unattached surface reports no foreground pid, so there is nothing to match")
    }

    @MainActor
    func testWorkspaceHelmDoesNotHostIsNeverInTheMap() async throws {
        try writeRow(pid: 9139, status: "idle")

        let board = BoardModel(manager: TerminalManager(), root: root)
        await board.refresh()

        XCTAssertTrue(
            board.presence.isEmpty,
            "the registry is full of other people's agents; helm reports only its own")
    }

    @MainActor
    func testRefreshOverAMissingRegistryIsQuietNotFatal() async {
        let board = BoardModel(
            manager: TerminalManager(), root: root.appendingPathComponent("never-created"))

        await board.refresh()

        XCTAssertTrue(board.presence.isEmpty)
    }

    @MainActor
    func testPollStopsWhenItsTaskIsCancelled() async {
        // The loop is `refresh` then sleep; a cancelled sleep throws immediately,
        // so the guard is what has to stop it rather than spin.
        let board = BoardModel(manager: TerminalManager(), root: root)
        let poll = Task { await board.poll(every: .milliseconds(1)) }

        try? await Task.sleep(for: .milliseconds(20))
        poll.cancel()

        await poll.value  // hangs the test rather than failing it if the loop spins
    }
}
