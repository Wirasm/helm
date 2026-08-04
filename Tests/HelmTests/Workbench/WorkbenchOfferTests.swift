import XCTest

@testable import Helm

/// *Appear, don't seize* (#125). An agent putting an artifact on the bench uses the same
/// placement rules the operator's ⌘-click does, and then differs in exactly two ways: it
/// does not change what a slot is showing, and it does not move bench focus.
///
/// Those two are the whole guarantee, so each has a test that fails loudly if a future
/// `offer` starts routing through `insert` again.
final class WorkbenchOfferTests: XCTestCase {
    private let plan = CanvasSource.file("/tmp/plan.md")
    private let tasks = CanvasSource.file("/tmp/tasks.md")
    private let report = CanvasSource.file("/tmp/report.md")

    /// Element-wise, because `XCTAssertEqual`'s `accuracy:` overload is scalars only and
    /// a fraction that is 1/3 never compares equal to 0.3333… exactly.
    private func assertFractions(
        _ actual: [Double], _ expected: [Double], _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(
                pair.0, pair.1, accuracy: 1e-9, "\(message) [\(index)]", file: file, line: line)
        }
    }

    // MARK: - What a push must not disturb

    func testAPushDoesNotChangeWhatTheSlotIsShowing() {
        var bench = Workbench(terminal: UUID())
        let reading = Pane(content: .canvas(plan))
        bench.insert(reading, at: .column)
        let slot = bench.focusedSlot

        bench.offer(Pane(content: .canvas(tasks)), at: .tab(in: slot))

        XCTAssertEqual(
            bench.focusedPane?.id, reading.id,
            "the operator was reading plan.md — a pushed artifact must not replace it")
    }

    func testAPushDoesNotMoveBenchFocus() {
        var bench = Workbench(terminal: UUID())
        let terminalSlot = bench.focusedSlot

        bench.offer(Pane(content: .canvas(plan)), at: .column)

        XCTAssertEqual(
            bench.focusedSlot, terminalSlot,
            "focus is what every bench command acts on; an agent may not take it")
    }

    func testAPushIntoANewRowDoesNotMoveFocusEither() {
        var bench = Workbench(terminal: UUID())
        let terminalSlot = bench.focusedSlot
        let column = try? XCTUnwrap(bench.columns.first?.id)

        if let column {
            bench.offer(Pane(content: .canvas(plan)), at: .row(in: column))
        }

        XCTAssertEqual(bench.focusedSlot, terminalSlot)
    }

    // MARK: - But it does appear

    func testAPushedArtifactIsActuallyOnTheBench() {
        var bench = Workbench(terminal: UUID())
        let pushed = Pane(content: .canvas(plan))

        bench.offer(pushed, at: .column)

        XCTAssertNotNil(
            bench.pane(pushed.id),
            "appear, don't seize — not 'do not appear'")
        XCTAssertEqual(bench.pane(showing: plan), pushed.id)
    }

    func testAPushedTabIsReachableInTheSlotItLandedIn() {
        var bench = Workbench(terminal: UUID())
        bench.insert(Pane(content: .canvas(plan)), at: .column)
        let slot = bench.focusedSlot
        let pushed = Pane(content: .canvas(tasks))

        bench.offer(pushed, at: .tab(in: slot))

        XCTAssertNotNil(bench.pane(pushed.id), "a tab you cannot reach is hidden, not offered")
    }

    // MARK: - Re-offering what is already open

    func testPushingAnArtifactAlreadyOnTheBenchChangesNothing() {
        var bench = Workbench(terminal: UUID())
        bench.insert(Pane(content: .canvas(plan)), at: .column)
        bench.insert(Pane(content: .canvas(tasks)), at: .tab(in: bench.focusedSlot))
        let before = bench

        // The common case: the agent rewrote plan.md and re-offered it. FileWatcher has
        // already re-rendered that pane; pulling it forward would be the interruption.
        bench.offer(
            Pane(content: .canvas(plan)), at: .existing(try! XCTUnwrap(bench.pane(showing: plan))))

        XCTAssertEqual(bench.focusedSlot, before.focusedSlot)
        XCTAssertEqual(bench.focusedPane?.id, before.focusedPane?.id)
        XCTAssertEqual(bench.panes.count, before.panes.count, "and no second copy")
    }

    // MARK: - What it costs the panes already there (#177)

    func testAnOfferedRowTakesAnEqualShareRatherThanHalfTheColumn() {
        var bench = Workbench(terminal: UUID())
        let column = bench.columns[0].id
        bench.offer(Pane(content: .terminal(face: .terminal)), at: .row(in: column))

        assertFractions(
            bench.columns[0].slots.map(\.height), [0.5, 0.5],
            "the first spawn splits the column in two")

        bench.offer(Pane(content: .terminal(face: .terminal)), at: .row(in: column))

        assertFractions(
            bench.columns[0].slots.map(\.height), [1 / 3.0, 1 / 3.0, 1 / 3.0],
            "and the second takes a third, not half — squeezing the pane the operator is "
                + "working in is its own kind of seizing")
    }

    func testAnOfferedColumnTakesAnEqualShareToo() {
        var bench = Workbench(terminal: UUID())
        bench.offer(Pane(content: .canvas(plan)), at: .column)

        assertFractions(
            bench.columns.map(\.width), [0.5, 0.5],
            "the first canvas is the dock, at half the bench — #125's measured behaviour")

        bench.offer(Pane(content: .canvas(tasks)), at: .column)

        assertFractions(bench.columns.map(\.width), [1 / 3.0, 1 / 3.0, 1 / 3.0])
    }

    func testAnOfferedRowKeepsTheProportionsTheOperatorDragged() {
        var bench = Workbench(terminal: UUID())
        let column = bench.columns[0].id
        bench.offer(Pane(content: .terminal(face: .terminal)), at: .row(in: column))
        let slots = bench.columns[0].slots.map(\.id)
        bench.resizeSlot(slots[0], to: 0.8, against: slots[1])

        bench.offer(Pane(content: .terminal(face: .terminal)), at: .row(in: column))

        let heights = bench.columns[0].slots.map(\.height)
        XCTAssertEqual(
            heights[0] / heights[1], 4, accuracy: 1e-9,
            "the two panes that were there keep their 80/20 to each other")
        XCTAssertEqual(heights[2], 1 / 3.0, accuracy: 1e-9)
    }

    // MARK: - The contrast that makes the guarantee legible

    func testTheOperatorsOwnOpenStillSelectsAndFocuses() {
        var bench = Workbench(terminal: UUID())
        bench.insert(Pane(content: .canvas(plan)), at: .column)
        let slot = bench.focusedSlot
        let opened = Pane(content: .canvas(report))

        bench.insert(opened, at: .tab(in: slot))

        XCTAssertEqual(
            bench.focusedPane?.id, opened.id,
            "when the operator asks, seizing is the correct behaviour — offer is the "
                + "exception, and this is what it is an exception to")
    }
}
