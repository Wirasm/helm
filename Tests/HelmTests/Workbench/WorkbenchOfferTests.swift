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
