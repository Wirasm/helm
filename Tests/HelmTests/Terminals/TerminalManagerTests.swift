import HelmWire
import XCTest

@testable import Helm

/// Session **ownership** — a shell per terminal pane benchd's document names, grouped by
/// workspace, torn down by pane. Every session creates its surface from the manager's one shared
/// ghostty runtime, never from a workspace runtime.
///
/// Which terminals exist is the document's to say (`WorkbenchModel.apply`, pinned by
/// `WorkbenchClientModeTests`); this is the manager's half: `adopt` starts exactly the ones that
/// have no session yet, under the pane's own id.
@MainActor
final class TerminalManagerTests: XCTestCase {
    private let firstWorkspace = WorkspacePath("/tmp/helm-workspace-one")
    private let secondWorkspace = WorkspacePath("/tmp/helm-workspace-two")

    func testAdoptingStartsAShellUnderEachPanesOwnID() {
        let manager = TerminalManager()
        XCTAssertTrue(manager.sessions.isEmpty, "nothing starts a pty until a pane names one")
        let first = UUID()
        let second = UUID()

        manager.adopt(terminals: [first, second], in: firstWorkspace)

        XCTAssertEqual(
            manager.sessions(for: firstWorkspace).map(\.id), [first, second],
            "a terminal pane's id is its session's id, in the document's order")
        XCTAssertEqual(manager.activeWorkspacePath, firstWorkspace)
        XCTAssertTrue(manager.sessions(for: secondWorkspace).isEmpty)
    }

    /// A pane showing a benchd session (M3) runs `bench attach` in its pty, and only that pane:
    /// the command is the document's (`attachCommands`), keyed by pane, never a guess.
    func testAPaneShowingASessionRunsBenchAttachAndOnlyThatPane() throws {
        let manager = TerminalManager()
        let agent = UUID()
        let shell = UUID()
        let document = BenchDocument(
            workspaces: [
                .init(
                    path: firstWorkspace.value,
                    bench: ToyBench.bench([
                        .init(id: agent, surface: .terminal(agent: nil, session: "s3")),
                        .init(id: shell, surface: .terminal(agent: nil)),
                    ]))
            ], active: firstWorkspace.value)
        let attaching = document.workspaces[0].bench.attachCommands(bench: "/opt/it's/bench")
        XCTAssertEqual(attaching, [agent: #"'/opt/it'\''s/bench' 'attach' 's3'"#])

        manager.adopt(
            terminals: [agent, shell], in: firstWorkspace, attaching: attaching)

        let sessions = manager.sessions(for: firstWorkspace)
        XCTAssertEqual(
            sessions.first { $0.id == agent }?.hostView.configuration.command,
            attaching[agent])
        XCTAssertNil(
            try XCTUnwrap(sessions.first { $0.id == shell }).hostView.configuration.command,
            "every other terminal is the login shell")
    }

    func testTheBenchIsAskedForOnlyWhenAPaneShowsASession() {
        let plain = BenchDocument(
            workspaces: [
                .init(
                    path: firstWorkspace.value,
                    bench: ToyBench.bench([.init(id: UUID(), surface: .terminal(agent: nil))]))
            ], active: firstWorkspace.value)
        var asked = false
        let none = plain.workspaces[0].bench.attachCommands(
            bench: {
                asked = true; return "bench"
            }())
        XCTAssertTrue(none.isEmpty)
        XCTAssertFalse(asked, "no round trip to benchd for a bench of plain terminals")
    }

    func testAdoptingAgainStartsOnlyWhatHasNoSessionYet() {
        let manager = TerminalManager()
        let live = manager.adoptShell(in: firstWorkspace)
        let arrived = UUID()

        manager.adopt(terminals: [live.id, arrived], in: firstWorkspace)

        XCTAssertEqual(
            manager.sessions(for: firstWorkspace).map(\.id), [live.id, arrived],
            "a live session is kept, not restarted over")
        XCTAssertTrue(
            manager.sessions(for: firstWorkspace).first === live, "the same session object")
    }

    func testSessionsGroupByWorkspaceAndShareOneController() {
        let manager = TerminalManager()
        manager.adoptShell(in: firstWorkspace)
        manager.adoptShell(in: firstWorkspace)
        manager.adoptShell(in: secondWorkspace)
        manager.adoptShell(in: secondWorkspace)

        XCTAssertEqual(
            manager.sessions(for: firstWorkspace).count, 2, "first workspace owns two tabs")
        XCTAssertEqual(
            manager.sessions(for: secondWorkspace).count, 2, "second workspace owns two tabs")
        for session in manager.sessions {
            XCTAssertTrue(
                session.controller === manager.controller,
                "every workspace surface uses the one manager controller")
        }
    }

    func testSwitchingKeepsTheOtherWorkspacesSessions() {
        let manager = TerminalManager()
        let parked = manager.adoptShell(in: firstWorkspace)

        manager.adoptShell(in: secondWorkspace)

        XCTAssertEqual(manager.activeWorkspacePath, secondWorkspace)
        XCTAssertTrue(
            manager.sessions.contains { $0.id == parked.id },
            "switching must retain the background workspace's session")
    }

    func testFallbackTitlesUseCreationOrdinals() {
        let manager = TerminalManager()
        manager.adoptShell(in: firstWorkspace)
        manager.adoptShell(in: firstWorkspace)
        XCTAssertEqual(
            manager.sessions(for: firstWorkspace).map(\.displayTitle), ["shell 1", "shell 2"],
            "titles use creation ordinals")
        manager.surfaces.close(manager.sessions(for: firstWorkspace)[1].id)
        manager.adoptShell(in: firstWorkspace)
        XCTAssertEqual(
            manager.sessions(for: firstWorkspace).map(\.displayTitle), ["shell 1", "shell 3"],
            "ordinals never reuse a closed tab number")
    }

    // MARK: - Attention, driven by visibility

    /// These used to be driven through `manager.select`, which is gone: selection is the
    /// bench's and is per slot. What the rules always meant is *"can the operator see
    /// this one"*, which still has a single answer per session — so they are driven
    /// through `session.isVisible`, which `WorkbenchModel` pushes.

    func testBellOnAHiddenPaneMarksAndBecomingVisibleClears() {
        let manager = TerminalManager()
        manager.adoptShell(in: firstWorkspace)
        let session = try! XCTUnwrap(manager.sessions(for: firstWorkspace).first)

        session.terminalDidRingBell()
        XCTAssertTrue(session.hasBell, "a bell from a pane you cannot see marks it")

        session.isVisible = true
        XCTAssertFalse(session.hasBell, "looking at it acknowledges the bell")
    }

    func testBellOnAVisiblePaneIsNotMarked() {
        let manager = TerminalManager()
        manager.adoptShell(in: firstWorkspace)
        let session = try! XCTUnwrap(manager.sessions(for: firstWorkspace).first)
        session.isVisible = true

        session.terminalDidRingBell()

        XCTAssertFalse(session.hasBell, "visible panes do not retain a stale bell")
    }

    func testCommandFinishInAHiddenPaneMarksAndBecomingVisibleAcknowledges() {
        let manager = TerminalManager()
        manager.adoptShell(in: firstWorkspace)
        let session = try! XCTUnwrap(manager.sessions(for: firstWorkspace).first)

        session.terminalDidFinishCommand(exitCode: 1, durationNanos: 2_000_000_000)
        XCTAssertEqual(
            session.activity.outcome, .failure(exitCode: 1, durationNanos: 2_000_000_000),
            "a command finishing out of sight marks its tab")

        session.isVisible = true
        XCTAssertNil(session.activity.outcome, "looking at it acknowledges the mark")
    }

    func testCommandFinishInAVisiblePaneIsNotMarked() {
        let manager = TerminalManager()
        manager.adoptShell(in: firstWorkspace)
        let session = try! XCTUnwrap(manager.sessions(for: firstWorkspace).first)
        session.isVisible = true

        session.terminalDidFinishCommand(exitCode: 0, durationNanos: 1)

        XCTAssertNil(session.activity.outcome, "you watched it happen; it needs no chrome")
    }

    func testProgressReportSurvivesBecomingVisible() {
        let manager = TerminalManager()
        manager.adoptShell(in: firstWorkspace)
        let session = try! XCTUnwrap(manager.sessions(for: firstWorkspace).first)

        session.terminalDidReportProgress(state: .set, percent: 30)
        session.isVisible = true

        XCTAssertEqual(
            session.activity.progress, .percent(30),
            "progress is a live hint, not an attention mark — acknowledging must not clear it")
    }

    func testVisibilityOnlyAcknowledgesOnTheRisingEdge() {
        let manager = TerminalManager()
        manager.adoptShell(in: firstWorkspace)
        let session = try! XCTUnwrap(manager.sessions(for: firstWorkspace).first)
        session.isVisible = true

        session.isVisible = true
        session.terminalDidRingBell()

        XCTAssertFalse(
            session.hasBell,
            "reconcileSessions runs on every bench change, so a re-push of the same value "
                + "must not be an event")
    }

    func testClosingATabLeavesOthersOnSharedController() {
        let manager = TerminalManager()
        manager.adoptShell(in: firstWorkspace)
        manager.adoptShell(in: firstWorkspace)
        manager.adoptShell(in: firstWorkspace)
        let sessions = manager.sessions(for: firstWorkspace)
        let survivors = [sessions[0], sessions[2]]
        manager.surfaces.close(sessions[1].id)
        XCTAssertEqual(
            manager.sessions(for: firstWorkspace).map(\.id), survivors.map(\.id),
            "only requested tab closes")
        for session in survivors {
            XCTAssertTrue(
                session.controller === manager.controller, "survivors retain the shared runtime")
        }
    }

    func testManagersAreIsolatedFromEachOther() {
        let first = TerminalManager()
        let second = TerminalManager()
        XCTAssertFalse(
            first.controller === second.controller, "test managers own isolated controllers")
    }

}
