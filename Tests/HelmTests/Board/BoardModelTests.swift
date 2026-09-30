import HelmWire
import XCTest

@testable import Helm

/// The board's wiring: what benchd reports for each pane's session → rollup → published map, and
/// the poll loop's lifetime.
///
/// The report is benchd's answer to `sessions` (M5c, `SessionForegrounds`), so a test says what
/// benchd would answer. Nothing here reads a registry: helm has none to read.
final class BoardModelTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-board-workspace")

    @MainActor
    func testAPaneWhoseSessionReportsNothingContributesNoMark() async throws {
        let manager = TerminalManager()
        let session = manager.adoptShell(in: workspace)
        manager.foregrounds.set([session.id: 9139])

        let board = BoardModel(manager: manager)
        board.refresh()

        XCTAssertNil(board.presence[workspace.value], "a shell benchd has no report for")
    }

    @MainActor
    func testTheAgentInAPanesBenchdSessionMarksItsWorkspace() async throws {
        let manager = TerminalManager()
        let session = manager.adoptShell(in: workspace)
        manager.foregrounds.set(
            [session.id: 9139], reports: [session.id: .init(activity: "idle")])

        let board = BoardModel(manager: manager)
        board.refresh()

        XCTAssertEqual(board.presence[workspace.value], .notWorking)
    }

    @MainActor
    func testAReportForAPaneHelmDoesNotShowIsNeverInTheMap() async throws {
        let manager = TerminalManager()
        manager.foregrounds.set([UUID(): 9139], reports: [UUID(): .init(activity: "idle")])

        let board = BoardModel(manager: manager)
        board.refresh()

        XCTAssertTrue(board.presence.isEmpty, "helm reports only the panes it shows")
    }

    @MainActor
    func testAMarkClearsTheTickItsReportIsGone() async throws {
        let manager = TerminalManager()
        let session = manager.adoptShell(in: workspace)
        manager.foregrounds.set([session.id: 9139], reports: [session.id: .init(activity: "idle")])
        let board = BoardModel(manager: manager)
        board.refresh()
        XCTAssertEqual(board.presence[workspace.value], .notWorking)

        manager.foregrounds.set([session.id: 9139])
        board.refresh()

        XCTAssertNil(board.presence[workspace.value], "nothing to expire")
    }

    @MainActor
    func testPollStopsWhenItsTaskIsCancelled() async {
        // The loop is `refresh` then sleep; a cancelled sleep throws immediately,
        // so the guard is what has to stop it rather than spin.
        let board = BoardModel(manager: TerminalManager())
        let poll = Task { await board.poll(every: .milliseconds(1)) }

        try? await Task.sleep(for: .milliseconds(20))
        poll.cancel()

        await poll.value  // hangs the test rather than failing it if the loop spins
    }
}
