import XCTest
@testable import Helm

/// Grouping tests use a fresh manager: every session still creates its surface
/// from that manager's one shared ghostty runtime, never from a workspace runtime.
@MainActor
final class TerminalManagerTests: XCTestCase {
    private let firstWorkspace = "/tmp/helm-workspace-one"
    private let secondWorkspace = "/tmp/helm-workspace-two"

    func testFirstTerminalIsLazyPerWorkspace() {
        let manager = TerminalManager()
        XCTAssertTrue(manager.sessions.isEmpty, "unvisited workspaces must not allocate terminals")

        manager.activate(workspacePath: firstWorkspace)
        XCTAssertEqual(manager.sessions(for: firstWorkspace).count, 1, "first visit creates one shell")
        XCTAssertTrue(manager.sessions(for: secondWorkspace).isEmpty, "other workspaces remain lazy")
    }

    func testSessionsGroupByWorkspaceAndShareOneController() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal()
        manager.activate(workspacePath: secondWorkspace)
        manager.newTerminal()

        XCTAssertEqual(manager.sessions(for: firstWorkspace).count, 2, "first workspace owns two tabs")
        XCTAssertEqual(manager.sessions(for: secondWorkspace).count, 2, "second workspace owns two tabs")
        for session in manager.sessions {
            XCTAssertTrue(session.controller === manager.controller, "every workspace surface uses the one manager controller")
        }
    }

    func testSwitchingParksSessionsWithoutClosingThem() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let parked = try! XCTUnwrap(manager.selected)
        manager.activate(workspacePath: secondWorkspace)
        manager.activate(workspacePath: firstWorkspace)

        XCTAssertTrue(manager.sessions.contains { $0.id == parked.id }, "switching must retain the parked session")
        XCTAssertEqual(manager.selectedID, parked.id, "returning restores the workspace terminal selection")
    }

    func testClosingWorkspaceReleasesOnlyItsSessions() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal()
        manager.activate(workspacePath: secondWorkspace)
        let survivor = try! XCTUnwrap(manager.selected)

        manager.closeWorkspace(firstWorkspace)

        XCTAssertTrue(manager.sessions(for: firstWorkspace).isEmpty, "closing a workspace tears down its own terminal tabs")
        XCTAssertEqual(manager.sessions(for: secondWorkspace).map(\.id), [survivor.id], "other workspace sessions remain alive")
        XCTAssertTrue(survivor.controller === manager.controller, "teardown never replaces the shared controller")
    }

    func testCloseRefusesLastTerminalInEachWorkspace() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let only = try! XCTUnwrap(manager.selected)
        manager.close(only)
        XCTAssertEqual(manager.sessions(for: firstWorkspace).count, 1, "last terminal of a workspace cannot close")

        manager.newTerminal()
        manager.close(try! XCTUnwrap(manager.selected))
        XCTAssertEqual(manager.sessions(for: firstWorkspace).count, 1, "closing a non-last terminal leaves its workspace alive")
    }

    func testSelectionAndCreationStayInsideActiveWorkspace() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal()
        let firstIDs = manager.sessions(for: firstWorkspace).map(\.id)
        manager.activate(workspacePath: secondWorkspace)
        manager.select(index: 1)

        XCTAssertEqual(manager.selectedID, manager.sessions(for: secondWorkspace)[0].id, "out-of-range selection is ignored within its workspace")
        XCTAssertEqual(manager.sessions(for: firstWorkspace).map(\.id), firstIDs, "other workspace tabs are untouched")
    }

    func testStartsWithOneSessionThatCannotBeClosedAfterActivation() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        XCTAssertEqual(manager.sessions(for: firstWorkspace).count, 1, "a visited workspace starts with one session")
        XCTAssertFalse(manager.canClose, "the first workspace session cannot close")
        manager.close(try! XCTUnwrap(manager.selected))
        XCTAssertEqual(manager.sessions(for: firstWorkspace).count, 1, "closing the sole session is refused")
    }

    func testNewTerminalAppendsAndSelectsWithinWorkspace() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let first = try! XCTUnwrap(manager.selected)
        manager.newTerminal()
        let sessions = manager.sessions(for: firstWorkspace)
        XCTAssertEqual(sessions.map(\.id).first, first.id, "new tabs append in workspace order")
        XCTAssertEqual(manager.selectedID, sessions.last?.id, "new tab becomes selected")
        XCTAssertTrue(manager.canClose, "two workspace terminals permit closing one")
    }

    func testFallbackTitlesUseCreationOrdinals() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal()
        XCTAssertEqual(manager.sessions(for: firstWorkspace).map(\.displayTitle), ["shell 1", "shell 2"], "titles use creation ordinals")
        manager.close(manager.sessions(for: firstWorkspace)[1])
        manager.newTerminal()
        XCTAssertEqual(manager.sessions(for: firstWorkspace).map(\.displayTitle), ["shell 1", "shell 3"], "ordinals never reuse a closed tab number")
    }

    func testClosingSelectedMovesSelectionToNeighbor() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal(); manager.newTerminal()
        manager.select(index: 1)
        let middle = try! XCTUnwrap(manager.selected)
        manager.close(middle)
        let sessions = manager.sessions(for: firstWorkspace)
        XCTAssertFalse(sessions.contains { $0.id == middle.id }, "closed session is removed")
        XCTAssertEqual(manager.selectedID, sessions[1].id, "selection moves to the neighbor at the closed position")
    }

    func testClosingLastPositionSelectsNewLast() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal()
        manager.close(try! XCTUnwrap(manager.selected))
        XCTAssertEqual(manager.selectedID, manager.sessions(for: firstWorkspace)[0].id, "closing the final position selects the new last tab")
    }

    func testClosingUnselectedKeepsSelection() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let first = try! XCTUnwrap(manager.selected)
        manager.newTerminal()
        let second = try! XCTUnwrap(manager.selected)
        manager.close(first)
        XCTAssertEqual(manager.selectedID, second.id, "closing an unselected tab preserves selection")
    }

    func testBellOnInactiveTabMarksAndSelectionClears() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let first = try! XCTUnwrap(manager.selected)
        manager.newTerminal()
        first.terminalDidRingBell()
        XCTAssertTrue(first.hasBell, "bell on inactive tab marks it")
        manager.select(first)
        XCTAssertFalse(first.hasBell, "selecting acknowledges the bell")
    }

    func testBellOnSelectedTabIsNotMarked() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let selected = try! XCTUnwrap(manager.selected)
        selected.terminalDidRingBell()
        XCTAssertFalse(selected.hasBell, "visible tabs do not retain a stale bell")
    }

    func testCommandFinishInInactiveTabMarksAndSelectionAcknowledges() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let first = try! XCTUnwrap(manager.selected)
        manager.newTerminal()
        first.terminalDidFinishCommand(exitCode: 1, durationNanos: 2_000_000_000)
        XCTAssertEqual(first.activity.outcome, .failure(exitCode: 1, durationNanos: 2_000_000_000), "inactive completion marks its tab")
        manager.select(first)
        XCTAssertNil(first.activity.outcome, "selection acknowledges the completion mark")
    }

    func testCommandFinishInSelectedTabIsNotMarked() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let selected = try! XCTUnwrap(manager.selected)
        selected.terminalDidFinishCommand(exitCode: 0, durationNanos: 1)
        XCTAssertNil(selected.activity.outcome, "selected completion needs no chrome")
    }

    func testProgressReportSurvivesSelection() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        let first = try! XCTUnwrap(manager.selected)
        manager.newTerminal()
        first.terminalDidReportProgress(state: .set, percent: 30)
        manager.select(first)
        XCTAssertEqual(first.activity.progress, .percent(30), "selection preserves live progress")
    }

    func testClosingATabLeavesOthersOnSharedController() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal(); manager.newTerminal()
        let sessions = manager.sessions(for: firstWorkspace)
        let survivors = [sessions[0], sessions[2]]
        manager.close(sessions[1])
        XCTAssertEqual(manager.sessions(for: firstWorkspace).map(\.id), survivors.map(\.id), "only requested tab closes")
        for session in survivors {
            XCTAssertTrue(session.controller === manager.controller, "survivors retain the shared runtime")
            manager.select(session)
            XCTAssertEqual(manager.selectedID, session.id, "survivors remain selectable")
        }
    }

    func testManagersAreIsolatedFromEachOther() {
        let first = TerminalManager()
        let second = TerminalManager()
        XCTAssertFalse(first.controller === second.controller, "test managers own isolated controllers")
    }

    func testSelectByIndexIgnoresOutOfRange() {
        let manager = TerminalManager()
        manager.activate(workspacePath: firstWorkspace)
        manager.newTerminal()
        manager.select(index: 0)
        let first = manager.selectedID
        manager.select(index: 8)
        XCTAssertEqual(manager.selectedID, first, "out-of-range terminal index is a no-op")
    }
}
