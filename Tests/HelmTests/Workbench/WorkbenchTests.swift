import XCTest

@testable import Helm

/// Every structural rule of the bench.
///
/// **No `@MainActor`, no `TerminalManager`, no window.** `Workbench` is a plain value, so
/// the whole window manager is exercisable here. A test in this file that needs a runtime
/// is a test whose rule was put in the wrong place.
final class WorkbenchTests: XCTestCase {

    // MARK: - Helpers

    private func terminal(_ id: UUID = UUID(), face: TerminalFace = .terminal) -> Pane {
        Pane(id: id, content: .terminal(face: face))
    }

    private func canvas(_ path: String) -> Pane {
        Pane(content: .canvas(.file(path: path)))
    }

    /// The four invariants, as an assertion. Used both directly and by the scripted
    /// sequence below.
    private func assertInvariants(
        _ bench: Workbench, _ step: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(
            bench.columns.isEmpty, "\(step): columns is never empty", file: file, line: line)
        for column in bench.columns {
            XCTAssertFalse(
                column.slots.isEmpty, "\(step): no column has zero slots", file: file, line: line)
            let heights = column.slots.map(\.height)
            XCTAssertTrue(
                heights.allSatisfy { $0 > 0 }, "\(step): every height is positive", file: file,
                line: line)
            XCTAssertEqual(
                heights.reduce(0, +), 1, accuracy: 1e-9,
                "\(step): a column's heights sum to 1", file: file, line: line)
            for slot in column.slots {
                XCTAssertFalse(
                    slot.panes.isEmpty, "\(step): no slot has zero panes", file: file, line: line)
                XCTAssertTrue(
                    slot.panes.contains { $0.id == slot.selected },
                    "\(step): a slot's selection names a pane it holds", file: file, line: line)
            }
        }
        let widths = bench.columns.map(\.width)
        XCTAssertTrue(
            widths.allSatisfy { $0 > 0 }, "\(step): every width is positive", file: file, line: line
        )
        XCTAssertEqual(
            widths.reduce(0, +), 1, accuracy: 1e-9, "\(step): the widths sum to 1", file: file,
            line: line)
        XCTAssertTrue(
            bench.slots.contains { $0.id == bench.focusedSlot },
            "\(step): focus names a slot that exists", file: file, line: line)
    }

    // MARK: - Shape

    func testTheOneColumnOneSlotBenchIsTodaysApp() {
        let session = UUID()
        let bench = Workbench(terminal: session)

        XCTAssertEqual(bench.columns.count, 1, "today's frame is one column")
        XCTAssertEqual(bench.columns[0].slots.count, 1, "…one slot")
        XCTAssertEqual(bench.panes.map(\.id), [session], "…holding the one terminal")
        XCTAssertEqual(
            bench.columns[0].slots[0].selected, session, "which is that slot's selection")
        XCTAssertEqual(
            bench.focusedSlot, bench.columns[0].slots[0].id, "and the slot commands target")
        XCTAssertEqual(bench.terminalPaneIDs, [session], "a terminal pane's id IS its session id")
    }

    // MARK: - Closing

    func testClosingTheSelectedPaneSelectsTheNeighbourAtItsPosition() {
        let panes = [terminal(), terminal(), terminal()]
        var bench = Workbench(panes: panes, selecting: panes[1].id)

        XCTAssertTrue(bench.close(panes[1].id))

        XCTAssertEqual(
            bench.panes.map(\.id), [panes[0].id, panes[2].id], "the closed pane is removed")
        XCTAssertEqual(
            bench.columns[0].slots[0].selected, panes[2].id,
            "selection moves to the neighbour at the closed position")
    }

    func testClosingTheLastPositionSelectsTheNewLast() {
        let panes = [terminal(), terminal()]
        var bench = Workbench(panes: panes, selecting: panes[1].id)

        bench.close(panes[1].id)

        XCTAssertEqual(
            bench.columns[0].slots[0].selected, panes[0].id,
            "closing the final position selects the new last tab")
    }

    func testClosingAnUnselectedPaneKeepsTheSelection() {
        let panes = [terminal(), terminal()]
        var bench = Workbench(panes: panes, selecting: panes[1].id)

        bench.close(panes[0].id)

        XCTAssertEqual(
            bench.columns[0].slots[0].selected, panes[1].id,
            "closing an unselected tab preserves selection")
    }

    func testClosingTheLastPaneRemovesItsSlot() {
        var bench = Workbench(terminal: UUID())
        let below = terminal()
        bench.splitDown(with: below)
        XCTAssertEqual(bench.columns[0].slots.count, 2, "the split gave the column two slots")

        bench.close(below.id)

        XCTAssertEqual(bench.columns[0].slots.count, 1, "emptying a slot removes the slot")
        XCTAssertEqual(bench.columns.count, 1, "…and leaves its column alone")
    }

    func testClosingTheLastSlotRemovesItsColumn() {
        var bench = Workbench(terminal: UUID())
        let right = terminal()
        bench.splitRight(with: right)
        XCTAssertEqual(bench.columns.count, 2, "the split gave the bench two columns")

        bench.close(right.id)

        XCTAssertEqual(bench.columns.count, 1, "emptying a column removes the column")
        assertInvariants(bench, "after a column collapse")
    }

    func testTheLastPaneOfTheBenchRefusesToClose() {
        let only = terminal()
        var bench = Workbench(panes: [only])

        XCTAssertFalse(bench.canClose(only.id), "the bench's last pane cannot close")
        XCTAssertFalse(bench.close(only.id), "and close says so rather than emptying the bench")
        XCTAssertEqual(bench.panes.map(\.id), [only.id], "…leaving it exactly where it was")
    }

    func testClosingTheFocusedSlotMovesFocusToALiveNeighbour() {
        var bench = Workbench(terminal: UUID())
        let below = terminal()
        bench.splitDown(with: below)
        XCTAssertEqual(bench.focusedSlot, bench.columns[0].slots[1].id, "the split focused it")

        bench.close(below.id)

        XCTAssertTrue(
            bench.slots.contains { $0.id == bench.focusedSlot },
            "focus never survives as a dead id")
        XCTAssertEqual(bench.focusedSlot, bench.columns[0].slots[0].id, "it moves to the neighbour")
    }

    // MARK: - Focus

    func testFocusSurvivesAnInsertionBeforeIt() {
        var bench = Workbench(terminal: UUID())
        bench.splitDown(with: terminal())
        let focused = bench.focusedSlot
        XCTAssertEqual(
            bench.slots.firstIndex { $0.id == focused }, 1, "it starts second in the column")

        // Split the slot ABOVE it: a slot is inserted at position 1 and the focused one
        // is pushed to position 2.
        bench.focus(bench.slots[0].id)
        bench.splitDown(with: terminal())
        bench.focus(focused)

        XCTAssertEqual(
            bench.focusedSlot, focused,
            "an id still names the same slot after an insertion before it")
        XCTAssertEqual(
            bench.slots.firstIndex { $0.id == focused }, 2,
            "…whose position has moved, which is exactly why focus is not an index")
    }

    func testMovingFocusOffTheEdgeIsANoOp() {
        var bench = Workbench(terminal: UUID())
        bench.splitRight(with: terminal())
        let rightmost = bench.focusedSlot

        bench.moveFocus(.right)

        XCTAssertEqual(bench.focusedSlot, rightmost, "there is nothing to the right; do not wrap")
        bench.moveFocus(.left)
        XCTAssertEqual(bench.focusedSlot, bench.columns[0].slots[0].id, "…but left still moves")
    }

    func testMovingFocusSidewaysLandsAtTheSameDepthClamped() {
        var bench = Workbench(terminal: UUID())
        bench.splitRight(with: terminal())  // a second column with ONE slot
        bench.focus(bench.columns[0].slots[0].id)
        bench.splitDown(with: terminal())
        bench.splitDown(with: terminal())  // column 0 has three slots; focus is the third

        bench.moveFocus(.right)

        XCTAssertEqual(
            bench.focusedSlot, bench.columns[1].slots[0].id,
            "a shallower column clamps to its last slot rather than refusing the move")

        bench.moveFocus(.left)

        XCTAssertEqual(
            bench.focusedSlot, bench.columns[0].slots[0].id,
            "and coming back lands at THAT depth, not where you set off from — the bench "
                + "remembers no desired column, which is the simple rule and the predictable one")
    }

    // MARK: - Sizes

    func testColumnFractionsStaySummingToOneAcrossInsertAndClose() {
        var bench = Workbench(terminal: UUID())
        let second = terminal()
        bench.splitRight(with: second)
        XCTAssertEqual(bench.columns.map(\.width), [0.5, 0.5], "a split halves the column")

        let third = terminal()
        bench.insert(third, at: .column)
        assertInvariants(bench, "after appending a column")

        bench.close(second.id)
        assertInvariants(bench, "after closing a column")
        XCTAssertEqual(bench.columns.map(\.width).reduce(0, +), 1, accuracy: 1e-9)
    }

    /// The 2+1+1 bench the operator actually works in, and the rule #90's fix turns on: a
    /// divider is between two columns, so the columns it does not sit between must come
    /// out of the drag with the fractions they went in with. The earlier rule shared the
    /// remainder over all of them in proportion, and dragging one divider moved three
    /// columns.
    func testMovingADividerLeavesEveryOtherColumnExactlyAsItWas() {
        var bench = Workbench(terminal: UUID())
        bench.splitRight(with: terminal())
        bench.focus(bench.columns[0].slots[0].id)
        bench.splitRight(with: terminal())
        // Three columns at a quarter, a quarter and a half.
        XCTAssertEqual(bench.columns.map(\.width), [0.25, 0.25, 0.5])
        let untouched = bench.columns[2].width

        bench.resizeColumn(bench.columns[0].id, to: 0.4, against: bench.columns[1].id)

        XCTAssertEqual(bench.columns[0].width, 0.4, accuracy: 1e-9, "the dragged column obeys")
        XCTAssertEqual(
            bench.columns[1].width, 0.1, accuracy: 1e-9,
            "and its neighbour across the divider absorbs the whole difference")
        XCTAssertEqual(
            bench.columns[2].width, untouched, accuracy: 1e-12,
            "the column the divider does not touch is not touched")
        XCTAssertEqual(bench.columns.map(\.width).reduce(0, +), 1, accuracy: 1e-9)
    }

    func testADividerDraggedPastItsNeighbourLeavesASliver() {
        var bench = Workbench(terminal: UUID())
        bench.splitRight(with: terminal())

        bench.resizeColumn(bench.columns[0].id, to: 0, against: bench.columns[1].id)

        XCTAssertGreaterThanOrEqual(
            bench.columns[0].width, Workbench.minimumFraction,
            "a divider dragged to the edge leaves a sliver you can grab again")
        assertInvariants(bench, "after an extreme resize")
    }

    func testADividerDraggedTheOtherWayLeavesItsNeighbourASliver() {
        var bench = Workbench(terminal: UUID())
        bench.splitRight(with: terminal())

        bench.resizeColumn(bench.columns[0].id, to: 1, against: bench.columns[1].id)

        XCTAssertGreaterThanOrEqual(
            bench.columns[1].width, Workbench.minimumFraction,
            "the clamp holds at both ends of the drag, not only the near one")
        assertInvariants(bench, "after an extreme resize the other way")
    }

    /// Slots trade with a slot, and only with one in the same column — that is the only
    /// place a slot divider can sit. A pair from two different columns is not a divider
    /// and must do nothing rather than something arbitrary.
    func testASlotDividerRefusesAPairFromTwoDifferentColumns() throws {
        var bench = Workbench(terminal: UUID())
        bench.splitDown(with: terminal())
        let elsewhere = terminal()
        bench.insert(elsewhere, at: .column)
        let heights = bench.columns[0].slots.map(\.height)
        let stranger = try XCTUnwrap(bench.slot(for: elsewhere.id)?.id)

        bench.resizeSlot(bench.columns[0].slots[0].id, to: 0.9, against: stranger)

        XCTAssertEqual(bench.columns[0].slots.map(\.height), heights, "nothing moved")
    }

    // MARK: - The face (#37)

    func testTogglingTheFaceAffectsOnlyTheFocusedPane() {
        var bench = Workbench(terminal: UUID())
        let other = terminal()
        bench.splitRight(with: other)  // focus follows the new pane

        bench.toggleFace()

        XCTAssertEqual(
            bench.face(ofSelectedPaneIn: bench.focusedSlot), .chat, "the focused pane swapped")
        XCTAssertEqual(
            bench.face(ofSelectedPaneIn: bench.columns[0].slots[0].id), .terminal,
            "read one agent's prose while watching another's shell — the whole reason the face "
                + "left TerminalWorkspace's single @State")
    }

    func testTogglingTheFaceOnACanvasPaneDoesNothing() {
        var bench = Workbench(terminal: UUID())
        let page = canvas("/tmp/plan.md")
        bench.splitRight(with: page)
        let before = bench

        bench.toggleFace()

        XCTAssertEqual(bench, before, "⌘T with a canvas focused changes nothing at all")
        XCTAssertNil(
            bench.face(ofSelectedPaneIn: bench.focusedSlot),
            "a canvas has no face, which is how the slot strip renders no toggle")
    }

    func testTheFaceToggleReadsTheSlotsSelectedPaneOnly() {
        let shell = terminal()
        let page = canvas("/tmp/plan.md")
        var bench = Workbench(panes: [shell, page], selecting: page.id)

        XCTAssertNil(
            bench.face(ofSelectedPaneIn: bench.focusedSlot),
            "a slot showing its canvas tab offers no face")

        bench.select(shell.id)
        XCTAssertEqual(
            bench.face(ofSelectedPaneIn: bench.focusedSlot), .terminal,
            "switching back to the terminal tab offers it again")
    }

    // MARK: - Selecting

    func testSelectingAPaneTheBenchDoesNotHoldIsANoOp() {
        var bench = Workbench(terminal: UUID())
        let before = bench

        bench.select(UUID())

        XCTAssertEqual(bench, before, "an unknown pane id changes nothing")
    }

    func testSelectingATabAlsoFocusesItsSlot() {
        var bench = Workbench(terminal: UUID())
        let elsewhere = terminal()
        bench.splitRight(with: elsewhere)
        let firstColumnPane = bench.columns[0].slots[0].panes[0].id

        bench.select(firstColumnPane)

        XCTAssertEqual(
            bench.focusedSlot, bench.columns[0].slots[0].id,
            "clicking a tab is also saying which pane commands mean now")
    }

    func testVisiblePanesAreOnePerSlot() {
        let tabs = [terminal(), terminal()]
        var bench = Workbench(panes: tabs, selecting: tabs[0].id)
        let other = terminal()
        bench.splitRight(with: other)

        XCTAssertEqual(
            bench.visiblePaneIDs, [tabs[0].id, other.id],
            "several panes are on screen at once — which is what a bench means, and why "
                + "TerminalSession.isVisible replaced one app-level selectedID")
    }

    // MARK: - Invariants under a scripted sequence

    func testEveryMutationLeavesTheInvariantsIntact() {
        let first = UUID()
        var bench = Workbench(terminal: first)
        let second = terminal()
        let third = terminal()
        let page = canvas("/tmp/notes.md")
        let fourth = terminal()

        let script: [(String, (inout Workbench) -> Void)] = [
            ("splitRight", { $0.splitRight(with: second) }),
            ("splitDown", { $0.splitDown(with: third) }),
            ("insert tab", { $0.insert(page, at: .tab(in: $0.focusedSlot)) }),
            ("insert row", { $0.insert(fourth, at: .row(in: $0.columns[0].id)) }),
            ("insert column", { $0.insert(self.terminal(), at: .column) }),
            ("moveFocus up", { $0.moveFocus(.up) }),
            ("moveFocus left", { $0.moveFocus(.left) }),
            ("toggleFace", { $0.toggleFace() }),
            ("select", { $0.select(page.id) }),
            (
                "resizeColumn",
                { $0.resizeColumn($0.columns[0].id, to: 0.7, against: $0.columns[1].id) }
            ),
            (
                "resizeSlot",
                {
                    let slots = $0.columns[0].slots
                    $0.resizeSlot(slots[0].id, to: 0.9, against: slots[slots.count - 1].id)
                }
            ),
            ("close a canvas", { $0.close(page.id) }),
            ("close a terminal", { $0.close(third.id) }),
            ("close another", { $0.close(second.id) }),
            ("close the first", { $0.close(first) }),
        ]

        assertInvariants(bench, "the starting bench")
        for (name, mutate) in script {
            mutate(&bench)
            assertInvariants(bench, name)
        }
    }

    // MARK: - Persistence

    func testCodableRoundTripsEveryPaneKind() throws {
        var bench = Workbench(terminal: UUID())
        bench.insert(canvas("/tmp/plan.md"), at: .column)
        bench.insert(
            Pane(content: .canvas(.url(URL(string: "http://localhost:3000")!))),
            at: .tab(in: bench.focusedSlot))
        bench.insert(Pane(content: .canvas(.empty)), at: .row(in: bench.columns[0].id))
        bench.resizeColumn(bench.columns[0].id, to: 0.7, against: bench.columns[1].id)

        let data = try JSONEncoder().encode(bench)
        let restored = try JSONDecoder().decode(Workbench.self, from: data)

        XCTAssertEqual(restored, bench, "a bench round-trips whole, sizes and all")
    }

    func testTheEncodedShapeUsesNamedDiscriminators() throws {
        var bench = Workbench(terminal: UUID())
        bench.insert(canvas("/tmp/plan.md"), at: .column)

        let json = String(decoding: try JSONEncoder().encode(bench), as: UTF8.self)

        XCTAssertTrue(json.contains("\"kind\":\"terminal\""), json)
        XCTAssertTrue(json.contains("\"kind\":\"canvas\""), json)
        XCTAssertTrue(json.contains("\"kind\":\"file\""), json)
        XCTAssertTrue(json.contains("\"path\":\"\\/tmp\\/plan.md\""), json)
        XCTAssertFalse(
            json.contains("_0"),
            "the synthesized shape uses positional keys, which break on any reordering of the "
                + "cases and are unreadable in the stored blob")
    }

    func testAChatFaceDoesNotSurviveEncoding() throws {
        var bench = Workbench(terminal: UUID())
        bench.toggleFace()
        XCTAssertEqual(bench.face(ofSelectedPaneIn: bench.focusedSlot), .chat)

        let data = try JSONEncoder().encode(bench)
        let restored = try JSONDecoder().decode(Workbench.self, from: data)

        XCTAssertEqual(
            restored.face(ofSelectedPaneIn: restored.focusedSlot), .terminal,
            "the shell it named respawns empty, so restoring into the chat face would show "
                + "'no session is running' where a shell should be")
    }

    func testABenchWithNoPanesDoesNotDecode() {
        let empty = #"{"columns":[],"focusedSlot":"\#(UUID().uuidString)"}"#

        XCTAssertThrowsError(
            try JSONDecoder().decode(Workbench.self, from: Data(empty.utf8)),
            "a bench with nothing to render has nothing to invent either")
    }

    func testADecodedBenchIsNormalised() throws {
        // Widths that do not sum to 1 and a selection naming a pane the slot does not
        // hold: hand-edited, or written by an older build. Repaired, not rejected.
        let pane = UUID()
        let slot = UUID()
        let json = """
            {"columns":[{"id":"\(UUID().uuidString)","width":9,"slots":[
              {"id":"\(slot.uuidString)","height":4,"selected":"\(UUID().uuidString)",
               "panes":[{"id":"\(pane.uuidString)","content":{"kind":"terminal"}}]}]}],
             "focusedSlot":"\(UUID().uuidString)"}
            """

        let bench = try JSONDecoder().decode(Workbench.self, from: Data(json.utf8))

        XCTAssertEqual(bench.columns[0].width, 1, accuracy: 1e-9, "widths are rebalanced")
        XCTAssertEqual(bench.columns[0].slots[0].selected, pane, "selection is repaired")
        XCTAssertEqual(bench.focusedSlot, slot, "so is focus")
    }
}
