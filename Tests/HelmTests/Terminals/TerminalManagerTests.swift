import XCTest

@testable import Helm

/// Session **ownership** — creation, grouping, restore, teardown. Grouping tests use a
/// fresh manager: every session still creates its surface from that manager's one shared
/// ghostty runtime, never from a workspace runtime.
///
/// Selection is not here any more. `testSelectionAndCreationStayInsideActiveWorkspace`,
/// `testCloseRefusesLastTerminalInEachWorkspace`,
/// `testStartsWithOneSessionThatCannotBeClosedAfterActivation`,
/// `testNewTerminalAppendsAndSelectsWithinWorkspace`,
/// `testClosingSelectedMovesSelectionToNeighbor`, `testClosingLastPositionSelectsNewLast`,
/// `testClosingUnselectedKeepsSelection` and `testSelectByIndexIgnoresOutOfRange` **moved**
/// to `WorkbenchTests`, restated against `Workbench` — where the rules now live. None was
/// dropped.
@MainActor
final class TerminalManagerTests: XCTestCase {
    private let firstWorkspace = WorkspacePath("/tmp/helm-workspace-one")
    private let secondWorkspace = WorkspacePath("/tmp/helm-workspace-two")

    func testFirstTerminalIsLazyPerWorkspace() {
        let manager = TerminalManager()
        XCTAssertTrue(manager.sessions.isEmpty, "unvisited workspaces must not allocate terminals")

        manager.activate(workspacePath: firstWorkspace)
        XCTAssertEqual(
            manager.sessions(for: firstWorkspace).count, 1, "first visit creates one shell")
        XCTAssertTrue(
            manager.sessions(for: secondWorkspace).isEmpty, "other workspaces remain lazy")
    }

    func testRelaunchRebuildsTheTabRowUnderItsPersistedIDs() {
        let manager = TerminalManager()
        let first = UUID()
        let second = UUID()

        manager.activate(workspacePath: firstWorkspace, restoring: [first, second])

        XCTAssertEqual(
            manager.sessions(for: firstWorkspace).map(\.id), [first, second],
            "a restored workspace must rebuild every terminal it had, in order")
    }

    func testRestoringIsLazyAndHappensOnlyOnFirstVisit() {
        let manager = TerminalManager()
        let persisted = UUID()

        manager.activate(workspacePath: firstWorkspace, restoring: [persisted])
        XCTAssertTrue(
            manager.sessions(for: secondWorkspace).isEmpty,
            "restore must not spawn ptys for workspaces that have not been visited")

        manager.newTerminal(in: firstWorkspace)
        manager.activate(workspacePath: secondWorkspace)
        manager.activate(workspacePath: firstWorkspace, restoring: [persisted])

        XCTAssertEqual(
            manager.sessions(for: firstWorkspace).count, 2,
            "returning to a live workspace must keep its terminals, not restore over them")
    }

    func testWorkspaceWithNothingPersistedStillGetsOneShell() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace, restoring: [])

        XCTAssertEqual(
            manager.sessions(for: firstWorkspace).count, 1,
            "a never-visited workspace behaves exactly as it did before restore existed")
    }

    func testSessionsGroupByWorkspaceAndShareOneController() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal(in: firstWorkspace)
        manager.activate(workspacePath: secondWorkspace)
        manager.newTerminal(in: secondWorkspace)

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

    func testSwitchingParksSessionsWithoutClosingThem() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let parked = try! XCTUnwrap(manager.sessions(for: firstWorkspace).first)
        manager.activate(workspacePath: secondWorkspace)
        manager.activate(workspacePath: firstWorkspace)

        XCTAssertTrue(
            manager.sessions.contains { $0.id == parked.id },
            "switching must retain the parked session")
    }

    func testClosingWorkspaceReleasesOnlyItsSessions() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal(in: firstWorkspace)
        manager.activate(workspacePath: secondWorkspace)
        let survivor = try! XCTUnwrap(manager.sessions(for: secondWorkspace).first)

        manager.closeWorkspace(firstWorkspace)

        XCTAssertTrue(
            manager.sessions(for: firstWorkspace).isEmpty,
            "closing a workspace tears down its own terminal tabs")
        XCTAssertEqual(
            manager.sessions(for: secondWorkspace).map(\.id), [survivor.id],
            "other workspace sessions remain alive")
        XCTAssertTrue(
            survivor.controller === manager.controller,
            "teardown never replaces the shared controller")
    }

    func testFallbackTitlesUseCreationOrdinals() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal(in: firstWorkspace)
        XCTAssertEqual(
            manager.sessions(for: firstWorkspace).map(\.displayTitle), ["shell 1", "shell 2"],
            "titles use creation ordinals")
        manager.close(manager.sessions(for: firstWorkspace)[1])
        manager.newTerminal(in: firstWorkspace)
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
        manager.activate(workspacePath: firstWorkspace)
        let session = try! XCTUnwrap(manager.sessions(for: firstWorkspace).first)

        session.terminalDidRingBell()
        XCTAssertTrue(session.hasBell, "a bell from a pane you cannot see marks it")

        session.isVisible = true
        XCTAssertFalse(session.hasBell, "looking at it acknowledges the bell")
    }

    func testBellOnAVisiblePaneIsNotMarked() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let session = try! XCTUnwrap(manager.sessions(for: firstWorkspace).first)
        session.isVisible = true

        session.terminalDidRingBell()

        XCTAssertFalse(session.hasBell, "visible panes do not retain a stale bell")
    }

    func testCommandFinishInAHiddenPaneMarksAndBecomingVisibleAcknowledges() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
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
        manager.activate(workspacePath: firstWorkspace)
        let session = try! XCTUnwrap(manager.sessions(for: firstWorkspace).first)
        session.isVisible = true

        session.terminalDidFinishCommand(exitCode: 0, durationNanos: 1)

        XCTAssertNil(session.activity.outcome, "you watched it happen; it needs no chrome")
    }

    func testProgressReportSurvivesBecomingVisible() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let session = try! XCTUnwrap(manager.sessions(for: firstWorkspace).first)

        session.terminalDidReportProgress(state: .set, percent: 30)
        session.isVisible = true

        XCTAssertEqual(
            session.activity.progress, .percent(30),
            "progress is a live hint, not an attention mark — acknowledging must not clear it")
    }

    func testVisibilityOnlyAcknowledgesOnTheRisingEdge() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
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
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal(in: firstWorkspace)
        manager.newTerminal(in: firstWorkspace)
        let sessions = manager.sessions(for: firstWorkspace)
        let survivors = [sessions[0], sessions[2]]
        manager.close(sessions[1])
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
