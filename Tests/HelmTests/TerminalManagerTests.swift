import XCTest
@testable import Helm

/// Session bookkeeping without a GUI: creating a TerminalSession spins up a real
/// ghostty controller + NSView (proven headless-safe by GhosttySmokeTests), but
/// no window means no surface and no pty — so ordering, selection, close rules,
/// and fallback titles are all exercisable under `swift test`.
@MainActor
final class TerminalManagerTests: XCTestCase {
    func testStartsWithOneSessionThatCannotBeClosed() {
        let manager = TerminalManager()

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.selectedID, manager.sessions[0].id)
        XCTAssertFalse(manager.canClose)

        // Close on the last terminal must be a refused no-op.
        manager.close(manager.sessions[0])
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testNewTerminalAppendsAndSelects() {
        let manager = TerminalManager()
        let first = manager.sessions[0]

        manager.newTerminal()

        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(manager.sessions[0].id, first.id, "ordered: new tabs append")
        XCTAssertEqual(manager.selectedID, manager.sessions[1].id)
        XCTAssertTrue(manager.canClose)
    }

    func testFallbackTitlesUseCreationOrdinals() {
        let manager = TerminalManager()
        manager.newTerminal()

        XCTAssertEqual(manager.sessions.map(\.displayTitle), ["shell 1", "shell 2"])

        // Ordinals are monotonic, not index-based: close #2, open another —
        // it must be "shell 3", never a second "shell 2".
        manager.close(manager.sessions[1])
        manager.newTerminal()
        XCTAssertEqual(manager.sessions.map(\.displayTitle), ["shell 1", "shell 3"])
    }

    func testClosingSelectedMovesSelectionToNeighbor() {
        let manager = TerminalManager()
        manager.newTerminal()
        manager.newTerminal() // tabs: 1, 2, 3 — selected: 3

        // Close the selected middle-by-position tab; selection falls to the
        // nearest surviving neighbor at that position.
        manager.select(index: 1)
        let middle = manager.selected
        manager.close(middle)

        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertFalse(manager.sessions.contains { $0.id == middle.id })
        XCTAssertEqual(manager.selectedID, manager.sessions[1].id)
    }

    func testClosingLastPositionSelectsNewLast() {
        let manager = TerminalManager()
        manager.newTerminal() // tabs: 1, 2 — selected: 2

        manager.close(manager.selected)

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.selectedID, manager.sessions[0].id)
    }

    func testClosingUnselectedKeepsSelection() {
        let manager = TerminalManager()
        let first = manager.sessions[0]
        manager.newTerminal()
        let second = manager.selected

        manager.close(first)

        XCTAssertEqual(manager.selectedID, second.id)
    }

    func testBellOnInactiveTabMarksAndSelectionClears() {
        let manager = TerminalManager()
        let first = manager.sessions[0]
        manager.newTerminal() // selection moves to the new tab

        first.terminalDidRingBell()
        XCTAssertTrue(first.hasBell, "bell on an inactive tab must mark it")

        manager.select(first)
        XCTAssertFalse(first.hasBell, "selecting the tab acknowledges the bell")
    }

    func testBellOnSelectedTabIsNotMarked() {
        let manager = TerminalManager()

        manager.selected.terminalDidRingBell()

        XCTAssertFalse(
            manager.selected.hasBell,
            "the visible tab needs no indicator (and it would linger stale)"
        )
    }

    func testCommandFinishInInactiveTabMarksAndSelectionAcknowledges() {
        let manager = TerminalManager()
        let first = manager.sessions[0]
        manager.newTerminal() // selection moves to the new tab

        first.terminalDidFinishCommand(exitCode: 1, durationNanos: 2_000_000_000)
        XCTAssertEqual(
            first.activity.outcome,
            .failure(exitCode: 1, durationNanos: 2_000_000_000),
            "a command finishing in an inactive tab must mark it"
        )

        manager.select(first)
        XCTAssertNil(first.activity.outcome, "selecting the tab acknowledges the mark")
    }

    func testCommandFinishInSelectedTabIsNotMarked() {
        let manager = TerminalManager()

        manager.selected.terminalDidFinishCommand(exitCode: 0, durationNanos: 1)

        XCTAssertNil(manager.selected.activity.outcome, "active-tab finishes need no chrome")
    }

    func testProgressReportSurvivesSelection() {
        let manager = TerminalManager()
        let first = manager.sessions[0]
        manager.newTerminal()

        first.terminalDidReportProgress(state: .set, percent: 30)
        manager.select(first)

        XCTAssertEqual(
            first.activity.progress, .percent(30),
            "progress is a hint, not attention — selection must not clear it"
        )
    }

    func testSelectByIndexIgnoresOutOfRange() {
        let manager = TerminalManager()
        manager.newTerminal()
        manager.select(index: 0)
        XCTAssertEqual(manager.selectedID, manager.sessions[0].id)

        // ⌘9 with two tabs open: no-op, selection unchanged.
        manager.select(index: 8)
        XCTAssertEqual(manager.selectedID, manager.sessions[0].id)
    }
}
