import Combine
import XCTest

@testable import Helm

/// Moving a pane (#287) — the value operation, and the keystroke that reaches it.
///
/// **No window, no surface, no pty.** `Workbench` is a value, so every rule about where a pane
/// lands is exercisable here; the one test that needs a live model uses `WorkbenchModel`'s
/// isolated `TerminalManager`, which needs no window either. That is the whole reason #287 asked
/// for the primitive first.
final class WorkbenchMoveTests: XCTestCase {

    // MARK: - Helpers

    private func terminal(_ id: UUID = UUID()) -> Pane {
        Pane(id: id, content: .terminal(face: .terminal))
    }

    /// Where a pane sits, as the pair a reader of `snapshot.json` would see. The assertions
    /// below compare these rather than slot ids, because a slot id survives a move that changed
    /// nothing and a position does not.
    private func position(of pane: Pane.ID, in bench: Workbench) -> [Int]? {
        for (column, contents) in bench.columns.enumerated() {
            for (depth, slot) in contents.slots.enumerated()
            where slot.panes.contains(where: { $0.id == pane }) {
                return [column, depth]
            }
        }
        return nil
    }

    /// The whole bench as positions, for the assertions that are about *everything else* staying
    /// put.
    private func shape(_ bench: Workbench) -> [[[Pane.ID]]] {
        bench.columns.map { $0.slots.map { $0.panes.map(\.id) } }
    }

    /// A 2+1 bench — two stacked slots on the left, one on the right — which is the layout
    /// `AGENTS.md` records the operator actually using on the 14-inch panel.
    private func twoPlusOne() -> (Workbench, left: [Pane], right: Pane) {
        let left = [terminal(), terminal()]
        let right = terminal()
        var bench = Workbench(panes: [left[0]])
        bench.splitRight(with: right)
        bench.focus(bench.columns[0].slots[0].id)
        bench.splitDown(with: left[1])
        return (bench, left, right)
    }

    // MARK: - Inside the bench: the pane keeps the standing it had

    /// A pane with a slot to itself moving sideways takes the slot with it, and lands at the
    /// depth it had — which is what makes the move its own inverse.
    func testASoleOccupantCarriesItsSlotToTheAdjacentColumnAtTheSameDepth() throws {
        let (start, left, right) = twoPlusOne()
        var bench = start

        XCTAssertEqual(position(of: left[1].id, in: bench), [0, 1], "the lower-left pane")
        XCTAssertTrue(bench.move(left[1].id, .right), "there is a column to the right")

        XCTAssertEqual(
            position(of: left[1].id, in: bench), [1, 1],
            "it kept a slot of its own and landed at depth 1, not as a tab on the canvas")
        XCTAssertEqual(
            shape(bench), [[[left[0].id]], [[right.id], [left[1].id]]],
            "the pane it left behind stayed where it was")

        bench.move(left[1].id, .left)
        XCTAssertEqual(
            shape(bench), shape(start),
            "and sending it back restores the bench exactly — the depth is what makes a move "
                + "its own inverse")
    }

    /// Within a column the two slots trade places. Merging into the neighbour as a tab would
    /// hide a pane the operator could see, on a keystroke that says "move".
    func testASoleOccupantMovingVerticallyReordersTheColumn() {
        let (start, left, _) = twoPlusOne()
        var bench = start

        XCTAssertTrue(bench.move(left[0].id, .down))

        XCTAssertEqual(
            bench.columns[0].slots.map { $0.panes.map(\.id) }, [[left[1].id], [left[0].id]],
            "the two rows traded places rather than becoming one slot with two tabs")
        XCTAssertEqual(bench.columns[0].slots.count, 2, "…so the column still has two rows")
    }

    /// The sizes stay with the positions: a move reorders panes, it must not silently redraw
    /// proportions the operator dragged a divider to set.
    func testAReorderLeavesTheRowsTheHeightsTheOperatorDraggedThemTo() {
        let (start, left, _) = twoPlusOne()
        var bench = start
        let slots = bench.columns[0].slots
        bench.resizeSlot(slots[0].id, to: 0.8, against: slots[1].id)
        let dragged = bench.columns[0].slots.map(\.height)
        XCTAssertEqual(dragged[0], 0.8, accuracy: 1e-9, "the drag landed")

        bench.move(left[0].id, .down)

        // Compared against what the drag actually produced rather than against 0.8/0.2 written
        // out: `normalize()` divides through by the sum, so the second fraction is 0.2 to
        // within a double's last bit and not on the nose.
        XCTAssertEqual(
            bench.columns[0].slots.map(\.height), dragged,
            "the tall row is still on top — the panes moved through it, the bench did not resize")
        XCTAssertEqual(
            bench.columns[0].slots[0].panes.map(\.id), [left[1].id],
            "…and it is the other pane sitting in it now")
    }

    /// A pane sharing its slot had no slot of its own, so it is not given one: it joins the
    /// destination slot as a tab.
    func testATabbedPaneJoinsTheDestinationSlotAsATab() {
        let tabs = [terminal(), terminal()]
        let right = terminal()
        var bench = Workbench(panes: tabs, selecting: tabs[0].id)
        bench.splitRight(with: right)

        XCTAssertTrue(bench.move(tabs[1].id, .right))

        XCTAssertEqual(
            shape(bench), [[[tabs[0].id]], [[right.id, tabs[1].id]]],
            "it became a second tab beside the pane already there, not a row of its own")
    }

    /// What a vacated slot shows next is `close`'s rule, not a second one.
    func testTheSlotAPaneLeavesShowsTheNeighbourAtThatPosition() {
        let tabs = [terminal(), terminal(), terminal()]
        let right = terminal()
        var bench = Workbench(panes: tabs, selecting: tabs[1].id)
        bench.splitRight(with: right)

        bench.move(tabs[1].id, .right)

        XCTAssertEqual(
            bench.columns[0].slots[0].selected, tabs[2].id,
            "the tab at the vacated position, exactly as closing that tab would have selected")
    }

    // MARK: - Emptied columns

    /// The acceptance criterion #287 words as *"an emptied column behaves the way closing the
    /// last pane in one already does"* — measured against `close` on the same bench rather than
    /// against a description of it.
    func testAColumnEmptiedByAMoveGoesExactlyAsAColumnEmptiedByACloseDoes() {
        let (start, left, right) = twoPlusOne()

        var moved = start
        moved.move(right.id, .left)

        var closed = start
        closed.close(right.id)

        XCTAssertEqual(moved.columns.count, 1, "the right column had one pane and it left")
        XCTAssertEqual(
            moved.columns.count, closed.columns.count,
            "a move and a close leave the same number of columns")
        XCTAssertEqual(
            moved.columns[0].width, closed.columns[0].width,
            "…and the same widths, because both leave the repair to normalize()")
        XCTAssertEqual(
            Set(moved.panes.map(\.id)), Set([left[0].id, left[1].id, right.id]),
            "the difference is the whole point: a move keeps the pane, a close destroys it")
    }

    // MARK: - The edge

    /// Reversibility, which is the argument for the edge rule existing at all: without it every
    /// move can reduce the column count and no move can restore it.
    func testAMoveOffTheEndOfTheBenchGivesThePaneAColumnOfItsOwn() {
        let (start, _, right) = twoPlusOne()
        var bench = start

        bench.move(right.id, .left)
        XCTAssertEqual(bench.columns.count, 1, "the bench collapsed to one column")

        XCTAssertTrue(bench.move(right.id, .right), "and the move back is available")
        XCTAssertEqual(
            shape(bench), shape(start),
            "which restores the 2+1 bench exactly — the ratchet the guard exists to prevent")
    }

    /// The vertical half of the same rule: a tab at the bottom of its column leaves for a row of
    /// its own, which is how a tab is pulled out into the open.
    func testATabAtTheEndOfItsColumnLeavesForARowOfItsOwn() {
        let tabs = [terminal(), terminal()]
        var bench = Workbench(panes: tabs, selecting: tabs[0].id)

        XCTAssertTrue(bench.move(tabs[0].id, .down))

        XCTAssertEqual(
            shape(bench), [[[tabs[1].id], [tabs[0].id]]],
            "one column, two rows — the tab is visible now instead of hidden behind its sibling")
    }

    /// The guard. A pane that is the only thing in the last column would be torn out and put
    /// back into an identical new one, so nothing happens instead — otherwise holding the key
    /// down would rebuild a column id for ever.
    func testAPaneAloneInTheLastColumnCannotChurnItsWaySideways() {
        let only = UUID()
        var bench = Workbench(terminal: only)
        let before = bench

        XCTAssertFalse(bench.move(only, .right), "there is nothing to leave")
        XCTAssertFalse(bench.move(only, .left), "…in either direction")
        XCTAssertFalse(bench.move(only, .down), "…nor vertically")
        XCTAssertFalse(bench.move(only, .up))
        XCTAssertEqual(bench, before, "and the bench is untouched, not rebuilt")
    }

    /// The same guard one level up: the bench's rightmost pane, alone in its column, stays.
    func testTheLastColumnsOnlyPaneStaysWhereItIs() {
        let (start, _, right) = twoPlusOne()
        var bench = start

        XCTAssertFalse(bench.move(right.id, .right), "it is already a column at that end")
        XCTAssertEqual(bench, start)
    }

    /// A pane nothing holds is not an error and not a crash — the same shape as `close`'s
    /// refusal, and the answer an addressed request from outside will need.
    func testMovingAPaneTheBenchDoesNotHoldReportsThatItDidNot() {
        var bench = Workbench(terminal: UUID())
        let before = bench

        XCTAssertFalse(bench.move(UUID(), .right))
        XCTAssertEqual(bench, before)
    }

    // MARK: - Controls

    /// **A control, and it is here because every focus assertion in this file is satisfied by a
    /// move that does nothing.** `focusedSlot` not changing is the *point* of the two branches
    /// where the slot travels with its id — and a `move` that returned without touching anything
    /// would pass those assertions perfectly. This one fails on a no-op: it requires the pane to
    /// be somewhere else afterwards, in every direction that has somewhere to go.
    func testEveryDirectionActuallyRelocatesThePaneAControl() {
        let (start, left, right) = twoPlusOne()

        for (direction, pane, from) in [
            (Workbench.Direction.right, left[1].id, [0, 1]),
            (.left, right.id, [1, 0]),
            (.up, left[1].id, [0, 1]),
            (.down, left[0].id, [0, 0]),
        ] {
            var bench = start
            XCTAssertEqual(position(of: pane, in: bench), from, "\(direction) starts here")

            XCTAssertTrue(bench.move(pane, direction), "\(direction) reported that it moved")

            XCTAssertNotEqual(
                position(of: pane, in: bench), from,
                "move \(direction) left the pane at \(from) — a move that moves nothing passes "
                    + "every focus assertion in this file")
            XCTAssertNotEqual(
                shape(bench), shape(start), "…and the bench is a different bench")
        }
    }

    /// **The second control, over the whole file's premise.** A move must conserve panes: one
    /// that dropped the pane it was carrying would satisfy "it is not where it was" and every
    /// emptied-column assertion above.
    func testAMoveNeverLosesOrDuplicatesAPaneAControl() {
        let (start, _, _) = twoPlusOne()
        let expected = Set(start.panes.map(\.id))

        for direction in [Workbench.Direction.left, .right, .up, .down] {
            for pane in expected {
                var bench = start
                bench.move(pane, direction)
                XCTAssertEqual(
                    Set(bench.panes.map(\.id)), expected,
                    "moving \(pane) \(direction) changed which panes exist")
                XCTAssertEqual(
                    bench.panes.count, expected.count, "…or left a duplicate of one")
            }
        }
    }

    // MARK: - Focus follows the pane

    /// The decision this PR makes, and the reason it is safe to make: the caller is the operator,
    /// pressing a key, looking at the pane. Their keyboard must not be left in the slot the pane
    /// vacated.
    func testTheOperatorsKeyboardTravelsWithThePaneItMoved() {
        let tabs = [terminal(), terminal()]
        let right = terminal()
        var bench = Workbench(panes: tabs, selecting: tabs[1].id)
        bench.splitRight(with: right)
        bench.select(tabs[1].id)
        let vacated = bench.focusedSlot

        bench.move(tabs[1].id, .right)

        XCTAssertNotEqual(bench.focusedSlot, vacated, "the keyboard did not stay behind")
        XCTAssertEqual(
            bench.focusedPane?.id, tabs[1].id,
            "the focused pane is the one that moved — anything else sends the operator's next "
                + "keystroke to a pane they are no longer looking at")
    }

    /// The other half: where the pane's whole slot travels, the keyboard is in the *same* slot
    /// afterwards, because `focusedSlot` is an id and the id went with it. An index would have
    /// gone stale here, which is the reason it is an id.
    func testFocusStaysWithTheSlotThatTravelled() {
        let (start, _, right) = twoPlusOne()
        var bench = start
        bench.select(right.id)
        let slot = bench.focusedSlot

        bench.move(right.id, .left)

        XCTAssertEqual(
            bench.focusedSlot, slot, "the same slot, now in the other column")
        XCTAssertEqual(bench.focusedPane?.id, right.id)
    }

    /// **One rule for every branch, which is what collapsing the three assignments into one
    /// block bought.** It used to be that a move of a pane the operator was *not* in took their
    /// keyboard in the three tab branches and left it alone in the two slot branches — a
    /// difference nobody chose, produced by where the assignments happened to sit. The rule is
    /// now sayable in one sentence, so it is asserted in one test: after a move, the keyboard is
    /// on the pane that moved.
    func testTheKeyboardLandsOnTheMovedPaneWhicheverBranchRan() {
        let (start, left, right) = twoPlusOne()

        for (label, pane, direction) in [
            ("a slot relocating sideways", left[1].id, Workbench.Direction.right),
            ("a slot reordering", left[0].id, .down),
            ("a pane leaving for a column of its own", right.id, .left),
        ] {
            var bench = start
            // Focus somewhere else entirely, so "it followed" cannot be "it never left".
            bench.select(left[0].id)

            bench.move(pane, direction)

            XCTAssertEqual(
                bench.focusedPane?.id, pane,
                "\(label): the keyboard is on the pane that moved")
        }
    }

    // MARK: - Invariants

    /// Every branch of `move`, against the bench's four invariants. `WorkbenchTests` runs the
    /// same assertions over the older mutations; this is the same shape for the new one, and it
    /// is the test that would catch a slot left empty or a fraction left summing to 1.3.
    func testEveryBranchOfAMoveLeavesTheInvariantsIntact() {
        let (start, left, right) = twoPlusOne()

        let script: [(String, (inout Workbench) -> Void)] = [
            ("sideways, sole occupant", { $0.move(left[1].id, .right) }),
            ("vertical, reorder", { $0.move(left[0].id, .down) }),
            ("off the end of the bench", { $0.move(right.id, .left) }),
            ("back off the end again", { $0.move(right.id, .right) }),
            ("a tab out of its slot", { $0.move($0.columns[0].slots[0].panes[0].id, .right) }),
            ("off the end of a column", { $0.move($0.panes[0].id, .down) }),
            ("into a wall", { $0.move($0.panes[0].id, .up) }),
        ]

        var bench = start
        assertInvariants(bench, "the starting bench")
        for (name, mutate) in script {
            mutate(&bench)
            assertInvariants(bench, name)
        }
    }

    /// The four invariants `Workbench`'s own header lists. A local copy of `WorkbenchTests`'
    /// helper, which is private to that file — reaching into it would mean editing a file this
    /// change has no other reason to touch.
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
                heights.reduce(0, +), 1, accuracy: 1e-9, "\(step): a column's heights sum to 1",
                file: file, line: line)
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
            widths.allSatisfy { $0 > 0 }, "\(step): every width is positive", file: file,
            line: line)
        XCTAssertEqual(
            widths.reduce(0, +), 1, accuracy: 1e-9, "\(step): the widths sum to 1", file: file,
            line: line)
        XCTAssertTrue(
            bench.slots.contains { $0.id == bench.focusedSlot },
            "\(step): focus names a slot that exists", file: file, line: line)
    }
}

// MARK: - The keystroke

/// The route from ⌘⌥⇧arrow to the value operation above.
///
/// Split from the value tests because it is `@MainActor` — but still no window: `WorkbenchModel`
/// builds its sessions from an isolated `TerminalManager`, which is what `init(terminals:)` is
/// for. Nothing here needs a ghostty surface, so nothing here is subject to #253.
@MainActor
final class MovePaneKeystrokeTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-move-pane")

    /// The map's half. ⌘⌥arrow is focus, ⌘⌥⇧arrow is the pane — one keystroke apart, which is
    /// the gesture's whole claim to being learnable.
    func testShiftTurnsTheFocusBindingIntoAPaneMove() {
        for (keyCode, direction) in [
            (UInt16(123), Workbench.Direction.left), (124, .right), (126, .up), (125, .down),
        ] {
            XCTAssertEqual(
                Shortcut.match(
                    characters: nil, keyCode: keyCode, modifiers: [.command, .option, .shift],
                    terminalFocused: true)?.command,
                .movePane(direction),
                "⇧⌥⌘ keyCode \(keyCode)")
            XCTAssertEqual(
                Shortcut.match(
                    characters: nil, keyCode: keyCode, modifiers: [.command, .option],
                    terminalFocused: true)?.command,
                .moveFocus(direction),
                "…and without shift it is still focus movement, keyCode \(keyCode)")
        }
    }

    /// Every move row is in the menu and posts what its title says. #152 is the reason this is
    /// asserted rather than assumed: four View ▸ Focus rows were silent no-ops for as long as
    /// the payload rode in an untyped `Notification.object`.
    func testEveryMoveRowIsClickableAndPostsItsOwnDirection() throws {
        let rows = Shortcut.all.filter { if case .movePane = $0.command { true } else { false } }
        XCTAssertEqual(rows.count, 4, "one row per arrow")

        for row in rows {
            let menu = try XCTUnwrap(row.menu, "a move row not in the menu cannot be clicked")
            XCTAssertTrue(menu.title.hasPrefix("Move Pane "), menu.title)

            var delivered: [HelmCommand] = []
            let token = HelmCommand.publisher.sink { delivered.append($0) }
            defer { token.cancel() }

            row.post()

            XCTAssertEqual(
                delivered, [row.command],
                "\(menu.title) posted \(delivered) — the row and the channel disagree")
        }
    }

    /// The end of it: the posted command reaches a live bench and moves a pane. A command the
    /// subscriber drops looks exactly like a command nothing binds, which is what #152 was.
    func testThePostedCommandMovesAPaneOnALiveBench() {
        let model = WorkbenchModel(terminals: TerminalManager())
        model.activate(workspacePath: workspace)
        model.splitRight()
        let moved = model.bench?.focusedPane?.id
        XCTAssertEqual(model.bench?.columns.count, 2, "two columns to move between")

        HelmCommand.movePane(.left).post()
        Eventually.holds { model.bench?.columns.count == 1 }

        XCTAssertEqual(
            model.bench?.columns.count, 1,
            "⇧⌥⌘← did nothing — WorkbenchModel is dropping a command the map posts")
        XCTAssertEqual(
            model.bench?.focusedPane?.id, moved,
            "and the operator's keyboard came with it")
    }
}
