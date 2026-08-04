import XCTest

@testable import Helm

/// The closed set of three (#33), plus the zeroth answer that keeps ⌘-clicking the same
/// link twice from opening two copies.
final class WorkbenchPlacementTests: XCTestCase {
    private let plan = CanvasSource.file("/tmp/plan.md")
    private let tasks = CanvasSource.file("/tmp/tasks.md")

    private func terminal() -> Pane { Pane(content: .terminal(face: .terminal)) }

    func testAnAlreadyOpenSourceIsSelectedRatherThanOpenedAgain() {
        var bench = Workbench(terminal: UUID())
        let open = Pane(content: .canvas(plan))
        bench.insert(open, at: .column)

        XCTAssertEqual(
            bench.placement(forOpening: plan), .existing(open.id),
            "⌘-clicking the same link twice selects the canvas you already have")
    }

    func testTodaysFrameAtOneByOnePutsTheFirstCanvasInANewColumn() {
        let bench = Workbench(terminal: UUID())

        XCTAssertEqual(
            bench.placement(forOpening: plan), .column,
            "the canvas appears to the right of the terminal, exactly where the dock was")
    }

    func testAFocusedSlotAlreadyHoldingACanvasTakesTheNewOneAsATab() {
        var bench = Workbench(terminal: UUID())
        bench.insert(Pane(content: .canvas(plan)), at: .column)
        let canvasSlot = bench.focusedSlot

        XCTAssertEqual(
            bench.placement(forOpening: tasks), .tab(in: canvasSlot),
            "the tenth offered canvas must not create a tenth column")
    }

    func testAnyOtherSlotHoldingACanvasTakesItWhenTheFocusedOneDoesNot() {
        var bench = Workbench(terminal: UUID())
        bench.insert(Pane(content: .canvas(plan)), at: .column)
        let canvasSlot = bench.focusedSlot
        bench.focus(bench.columns[0].slots[0].id)  // back to the terminal column

        XCTAssertEqual(
            bench.placement(forOpening: tasks), .tab(in: canvasSlot),
            "the first slot in column order that holds a canvas takes it")
    }

    func testASlotMixingATerminalAndACanvasStillCountsAsACanvasSlot() {
        let shell = terminal()
        let page = Pane(content: .canvas(plan))
        let bench = Workbench(panes: [shell, page], selecting: shell.id)

        XCTAssertEqual(
            bench.placement(forOpening: tasks), .tab(in: bench.focusedSlot),
            "the operator put a canvas there, so that is where canvases go")
    }

    func testANewTerminalIsATabInTheFocusedSlot() {
        var bench = Workbench(terminal: UUID())
        bench.splitRight(with: terminal())

        XCTAssertEqual(
            bench.placementForNewTerminal(), .tab(in: bench.focusedSlot),
            "⌘N appends to the slot you are in — what TerminalManager.newTerminal did")
    }

    // MARK: - A spawn (#177)

    func testASpawnWhileACanvasHasFocusIsNotATabOnTheCanvas() {
        var bench = Workbench(terminal: UUID())
        bench.insert(Pane(content: .canvas(plan)), at: .column)
        let canvasSlot = bench.focusedSlot

        let placement = bench.placementForSpawnedTerminal()

        XCTAssertNotEqual(
            placement, .tab(in: canvasSlot),
            "the operator was reading a canvas; an agent from outside stacked onto it (#177)")
        XCTAssertEqual(
            placement, .row(in: bench.columns[0].id),
            "it joins the column that already holds terminals, as a pane of its own")
    }

    func testASpawnIgnoresFocusEvenWhenFocusIsOnATerminal() {
        let bench = Workbench(terminal: UUID())

        XCTAssertEqual(
            bench.placementForNewTerminal(), .tab(in: bench.focusedSlot),
            "⌘N is unchanged: the operator asking for a terminal gets it where they are")
        XCTAssertEqual(
            bench.placementForSpawnedTerminal(), .row(in: bench.columns[0].id),
            "a spawn is decided by the bench, not by whatever was last clicked — a tab is "
                + "hidden, and a spawn nobody is watching must be visible")
    }

    func testASpawnJoinsTheFirstColumnHoldingATerminal() {
        var bench = Workbench(panes: [Pane(content: .canvas(plan))])
        bench.insert(terminal(), at: .column)
        bench.insert(terminal(), at: .column)

        XCTAssertEqual(
            bench.placementForSpawnedTerminal(), .row(in: bench.columns[1].id),
            "the first column in bench order that holds a terminal takes it — the mirror of "
                + "the canvas rule, one level up")
    }

    func testASpawnOntoAnAllCanvasBenchGetsAColumnOfItsOwn() {
        var bench = Workbench(panes: [Pane(content: .canvas(plan))])
        bench.insert(Pane(content: .canvas(tasks)), at: .column)

        XCTAssertEqual(
            bench.placementForSpawnedTerminal(), .column,
            "there is no column of agents to join, and a canvas slot is the one place a "
                + "spawn must not land")
    }

    func testPathsAreStandardisedSoTheSameFileIsOneCanvas() {
        var bench = Workbench(terminal: UUID())
        let open = Pane(content: .canvas(.file(URL(fileURLWithPath: "/tmp/./plan.md"))))
        bench.insert(open, at: .column)

        XCTAssertEqual(
            bench.placement(forOpening: .file(URL(fileURLWithPath: "/tmp/plan.md"))),
            .existing(open.id),
            "rule 1 compares by value, so an unstandardised path silently opens a second copy")
    }

    func testAURLSourceIsMatchedByValueToo() {
        var bench = Workbench(terminal: UUID())
        let localhost = URL(string: "http://localhost:3000")!
        let open = Pane(content: .canvas(.url(localhost)))
        bench.insert(open, at: .column)

        XCTAssertEqual(bench.placement(forOpening: .url(localhost)), .existing(open.id))
        XCTAssertEqual(
            bench.placement(forOpening: .url(URL(string: "http://localhost:4000")!)),
            .tab(in: bench.focusedSlot),
            "a different address is a different canvas, beside the one already open")
    }
}
