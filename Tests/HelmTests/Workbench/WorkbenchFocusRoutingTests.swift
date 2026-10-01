import AppKit
import Combine
import GhosttyTerminal
import HelmWire
import SwiftUI
import XCTest

@testable import Helm

/// **Does clicking a pane make it the pane commands act on.**
///
/// Nothing in this suite asked that before #152, and the reason it went unnoticed is worth
/// keeping: every existing test *selects a tab first*, and selecting a tab is exactly the path
/// that always worked. `Workbench`'s own tests drive `focus`/`select` directly, and
/// `TerminalKeyboardTests` proves the keyboard follows the bench — neither can see a click that
/// moves the keyboard and leaves the bench behind. A suite can be green and blind at once.
///
/// These build the real thing — a real `NSWindow`, the real `WorkbenchView` hierarchy, real
/// `TerminalSession`s on libghostty's in-memory backend — and push **mouse** events through
/// `NSApp.sendEvent`. Not `NSWindow.sendEvent`, which is what the keyboard tests use: a local
/// event monitor is installed on the *application's* dispatch, so a window-level send would
/// never reach the mechanism under test and every assertion here would pass for the wrong
/// reason.
///
/// Click points are computed from the target view's own bounds, never written down. A stale
/// coordinate does not miss harmlessly — it lands in whatever is underneath.
@MainActor
final class WorkbenchFocusRoutingTests: XCTestCase {
    // MARK: - The click itself

    /// The whole ticket in one assertion: a click on a pane's **body**, with no tab selected
    /// first, moves the bench's focused slot.
    func testClickingAPanesBodyMovesTheFocusedSlot() throws {
        let bench = try Bench(terminals: 2)
        defer { bench.close() }

        let focused = try XCTUnwrap(bench.workbench.bench?.focusedSlot)
        let other = try XCTUnwrap(bench.workbench.bench?.slots.map(\.id).first { $0 != focused })

        try bench.clickPane(inSlot: other)

        Eventually.holds { bench.workbench.bench?.focusedSlot == other }
        XCTAssertEqual(
            bench.workbench.bench?.focusedSlot, other,
            "clicking a pane's body left the bench pointed at the slot it was already on")
    }

    /// **The reason this ticket was filed now.** ⌘⇧D does not merely act on the wrong pane, it
    /// *mutates the layout* — halving an untouched slot and inserting a pane the operator then
    /// has to find and close. The new slot must land under the slot that was clicked.
    func testSplitDownAfterAClickSplitsTheClickedSlot() throws {
        let bench = try Bench(terminals: 2)
        defer { bench.close() }

        let first = try XCTUnwrap(bench.workbench.bench?.slots.first?.id)
        let second = try XCTUnwrap(bench.workbench.bench?.slots.last?.id)
        XCTAssertEqual(
            bench.workbench.bench?.focusedSlot, first, "the fixture should start on the first slot")

        try bench.clickPane(inSlot: second)
        Eventually.holds { bench.workbench.bench?.focusedSlot == second }
        bench.command(.split(.down))

        Eventually.holds { bench.workbench.bench?.columns.first?.slots.count == 3 }
        let order = try XCTUnwrap(bench.workbench.bench?.columns.first?.slots.map(\.id))
        XCTAssertEqual(order.count, 3, "⌘⇧D did not add a slot")
        XCTAssertEqual(
            Array(order.prefix(2)), [first, second],
            "the new slot was inserted after the slot that was NOT clicked — the split landed on "
                + "the wrong pane, which is the layout mutation #152 is about")
        XCTAssertEqual(
            bench.workbench.bench?.focusedSlot, order[2], "focus should follow the new slot")
    }

    /// The loop closed end to end: the click moves the bench, the bench hands the grid the
    /// keyboard, and the keystroke comes out of that pane's pty. This is also the only
    /// assertion here that would fail if the monitor ever started **consuming** the click.
    func testTypingAfterAClickReachesTheClickedTerminal() throws {
        let bench = try Bench(terminals: 2)
        defer { bench.close() }

        let before = try XCTUnwrap(bench.workbench.bench?.focusedPane?.id)
        let clicked = try XCTUnwrap(bench.workbench.bench?.panes.map(\.id).first { $0 != before })

        try bench.clickPane(inSlot: try bench.slot(holding: clicked))
        let target = try bench.pty(of: clicked)
        let previous = try bench.pty(of: before)
        bench.type("x")

        XCTAssertTrue(target.received("x"), "the clicked terminal received nothing")
        XCTAssertFalse(
            previous.received.contains("x"),
            "the keystroke went to the terminal that was focused before the click")
    }

    // MARK: - What a click must NOT do

    /// Clicking where you already are is not a change, and must not be written as one: `commit`
    /// runs `reconcileSessions` and drives the save to `UserDefaults`, so an unguarded
    /// `focus` would persist the whole workspace context on every click in the pane you are
    /// typing in.
    func testClickingTheAlreadyFocusedPaneRewritesNothing() throws {
        let bench = try Bench(terminals: 2)
        defer { bench.close() }

        let focused = try XCTUnwrap(bench.workbench.bench?.focusedSlot)
        let before = try XCTUnwrap(bench.workbench.bench)

        try bench.clickPane(inSlot: focused)

        XCTAssertEqual(
            bench.workbench.bench, before,
            "clicking the focused pane produced a new bench value; every such commit is a "
                + "UserDefaults write")
    }

    /// ⌘O's artifact browser is a popover — its own window, over the bench. A click in it
    /// converts to a point squarely inside a slot's rectangle, so without the window check it
    /// would move focus underneath a control the operator is using.
    func testAClickInAnotherWindowIsNotThisBenchsClick() throws {
        let bench = try Bench(terminals: 2)
        defer { bench.close() }

        let focused = try XCTUnwrap(bench.workbench.bench?.focusedSlot)
        let other = try XCTUnwrap(bench.workbench.bench?.slots.map(\.id).first { $0 != focused })
        let point = try bench.centre(ofPaneInSlot: other)

        // The same point, attributed to a window that is not the bench's.
        bench.click(at: point, windowNumber: bench.window.windowNumber + 1_000)

        XCTAssertEqual(
            bench.workbench.bench?.focusedSlot, focused,
            "a click belonging to another window moved this bench's focus")
    }

    /// **Reaching for a divider must not take the keyboard with it.**
    ///
    /// A divider is a 1pt hairline with a 9pt grab overlay, and that overlay does not take
    /// part in layout — `SplitStack` gives it `zIndex(1)` precisely so the half overhanging
    /// the next member is not buried. So a mouse-down aimed squarely at the divider lands 4pt
    /// *inside* the pane above it, and a reporter reading its own rectangle would call that
    /// "focus the pane above" — moving the keyboard out of the pane the operator is typing in,
    /// which is #152 reopened through the resize handle rather than the pane click.
    ///
    /// The two stacked slots butt against one divider, so the upper slot's bottom edge in
    /// window coordinates *is* the divider, and two points above it is inside the grab band.
    func testAClickInADividersGrabBandDoesNotMoveFocus() throws {
        let bench = try Bench(terminals: 2)
        defer { bench.close() }

        let upper = try XCTUnwrap(bench.workbench.bench?.slots.first?.id)
        let lower = try XCTUnwrap(bench.workbench.bench?.slots.last?.id)

        try bench.clickPane(inSlot: lower)
        XCTAssertEqual(
            bench.workbench.bench?.focusedSlot, lower, "the fixture never reached the lower slot")

        let rect = try bench.paneRect(inSlot: upper)
        bench.click(
            at: NSPoint(x: rect.midX, y: rect.minY + 2), windowNumber: bench.window.windowNumber)

        XCTAssertEqual(
            bench.workbench.bench?.focusedSlot, lower,
            "a mouse-down in the divider's grab band moved focus to the pane above it — resizing "
                + "would carry the keyboard out of the pane being typed in")
    }

    /// **A zoomed bench is laid out past its own edges (⌘J, `BenchCamera`), and a slot out
    /// there still has its rectangle under the chrome.** Zoomed on the upper slot, the lower one
    /// runs on under the bar below the bench; a click on that bar is a click on the bar, and
    /// moving the keyboard to a slot the operator cannot see would also pan the camera away from
    /// the one he is looking at.
    func testAClickOnChromeOverAZoomedBenchsHiddenSlotDoesNotMoveFocus() throws {
        let bench = try Bench(terminals: 2, chromeBelow: 40)
        defer { bench.close() }

        let upper = try XCTUnwrap(bench.workbench.bench?.slots.first?.id)
        let lower = try XCTUnwrap(bench.workbench.bench?.slots.last?.id)
        XCTAssertEqual(bench.workbench.bench?.focusedSlot, upper)
        bench.workbench.isZoomed = true
        bench.settle()

        // The bar is the bottom 40pt of the window; window coordinates start at the bottom.
        let hidden = try bench.paneRect(inSlot: lower)
        XCTAssertLessThan(hidden.minY, 0, "the lower slot should run on past the bench when zoomed")
        let onBar = NSPoint(x: hidden.midX, y: 20)
        // Chrome drawn after the bench and below it, the status bar's shape in `RootView`, is
        // also the view AppKit hands the click to. Only that case is measured here: the
        // workspace bar above the bench (its `zIndex`) and the rail beside it are not.
        let hit = try XCTUnwrap(bench.window.contentView?.hitTest(onBar))
        XCTAssertFalse(
            sequence(first: hit, next: \.superview).contains { $0 is FocusClaimingTerminalView },
            "the hidden terminal, not the bar, takes a click on the bar")
        bench.click(at: onBar, windowNumber: bench.window.windowNumber)
        XCTAssertEqual(
            bench.workbench.bench?.focusedSlot, upper,
            "a click on the bar under a zoomed bench focused the slot hidden beneath it")

        // The control, which fails if the guard overshoots: the lower slot's visible sliver
        // is still the lower slot's, and a click there focuses it.
        bench.click(at: NSPoint(x: hidden.midX, y: 60), windowNumber: bench.window.windowNumber)
        Eventually.holds { bench.workbench.bench?.focusedSlot == lower }
        XCTAssertEqual(
            bench.workbench.bench?.focusedSlot, lower,
            "a click on the part of the lower slot that shows did not focus it")
    }

    /// The camera pans **to** the slot: zoomed on the lower of two stacked slots, that slot is
    /// held flush with the bench's bottom edge and whole on screen, while the upper one runs off
    /// the top. A pan applied the wrong way would push the zoomed slot off the window instead.
    func testAZoomedLowerSlotIsPannedIntoView() throws {
        let bench = try Bench(terminals: 2)
        defer { bench.close() }

        let upper = try XCTUnwrap(bench.workbench.bench?.slots.first?.id)
        let lower = try XCTUnwrap(bench.workbench.bench?.slots.last?.id)
        try bench.clickPane(inSlot: lower)
        Eventually.holds { bench.workbench.bench?.focusedSlot == lower }
        bench.workbench.isZoomed = true
        bench.settle()

        let window = try XCTUnwrap(bench.window.contentView?.bounds)
        let zoomed = try bench.paneRect(inSlot: lower)
        XCTAssertEqual(zoomed.minY, window.minY, accuracy: 1, "flush with the bench's bottom edge")
        XCTAssertLessThanOrEqual(zoomed.maxY, window.maxY, "the zoomed slot is whole on screen")
        XCTAssertGreaterThan(
            try bench.paneRect(inSlot: upper).maxY, window.maxY,
            "the upper slot runs on past the top")
    }

    // MARK: - The menu's route

    /// View ▸ Focus Left/Right/Up/Down were silent no-ops: the menu posted `payload`, which was
    /// nil on every row that carried a direction in a separate `direction` field (#152). The
    /// channel that let the menu and the keymap assemble a command differently is gone — both
    /// hand the row's own action to `Actions` — so what is left to ask is whether each row
    /// carries the direction its menu title claims. Every direction has exactly one item: the
    /// home-row letters (#498) are a second key for the same step and carry no item of their own.
    func testEveryFocusRowCarriesTheDirectionItsMenuNames() {
        let menus = KeyBindings.all.compactMap { row -> (BenchDirection, String)? in
            guard case let .verb(.stepFocus(direction)) = row.action, let menu = row.menu
            else { return nil }
            return (direction, menu)
        }
        XCTAssertEqual(
            Set(menus.map(\.0)), [.left, .right, .up, .down], "one clickable item per direction")
        XCTAssertEqual(menus.count, 4)
        for (direction, menu) in menus {
            XCTAssertEqual(menu, "Focus \(direction.rawValue.capitalized)")
        }
    }

    /// The end of it: the menu's route — the row's action, handed to the performer `RootView`
    /// composes — moves focus on a real bench, which no unit test on the table alone can reach.
    func testTheMenusFocusRowMovesFocusOnARealBench() throws {
        let bench = try Bench(terminals: 2)
        defer { bench.close() }
        let actions = LocalActions(
            workbench: bench.workbench, workspaces: WorkspaceModel(readBranch: { _ in nil }),
            terminals: bench.terminals)
        Actions.performer = actions
        defer { Actions.performer = nil }

        let before = try XCTUnwrap(bench.workbench.bench?.focusedSlot)
        let row = try XCTUnwrap(
            KeyBindings.all.first { $0.action == .verb(.stepFocus(.down)) && $0.menu != nil })

        Actions.perform(row.action)

        XCTAssertNotEqual(
            bench.workbench.bench?.focusedSlot, before,
            "View ▸ Focus Down did nothing — the menu's action never reached the bench")
    }
}

// MARK: - Harness

/// helm in a window, with two stacked slots and readable ptys (`WorkbenchWindow`), clicked the
/// way the operator clicks.
@MainActor
private final class Bench: WorkbenchWindow {
    /// `chromeBelow` puts a bar of that height under the bench, as the status bar sits under it
    /// in the app: somewhere a zoomed bench's off-screen slots lie under but cannot be clicked.
    init(terminals count: Int, chromeBelow: CGFloat = 0) throws {
        let panes = (0..<count).map { _ in ToyBench.terminal() }
        try super.init(
            bench: ToyBench.stacked(panes),
            workspacePath: NSTemporaryDirectory() + "focus-routing/",
            root: { workbenchView in
                VStack(spacing: 0) {
                    workbenchView
                    Color.surfaceRaised.frame(height: chromeBelow)
                }
            })
    }

    func slot(holding pane: Pane.ID) throws -> Slot.ID {
        try XCTUnwrap(workbench.bench?.slot(for: pane)?.id, "no slot holds pane \(pane)")
    }

    /// A slot's terminal grid in **window** coordinates — read off the view every time, never
    /// written down. Everything that needs a point computes it from this.
    func paneRect(inSlot slot: Slot.ID) throws -> NSRect {
        let pane = try XCTUnwrap(workbench.bench?.slot(slot)?.selected, "slot \(slot) is empty")
        let view = try XCTUnwrap(
            terminals.sessions.first { $0.id == pane }?.hostView, "no view for pane \(pane)")
        XCTAssertFalse(
            view.bounds.isEmpty, "the pane's view has no size; a click cannot land in it")
        return view.convert(view.bounds, to: nil)
    }

    /// The middle of the terminal grid in a slot, in window coordinates.
    func centre(ofPaneInSlot slot: Slot.ID) throws -> NSPoint {
        let rect = try paneRect(inSlot: slot)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    func clickPane(inSlot slot: Slot.ID) throws {
        click(at: try centre(ofPaneInSlot: slot), windowNumber: window.windowNumber)
    }

    /// A mouse-down through **`NSApp`**, not the window: local monitors are installed on the
    /// application's dispatch, so `window.sendEvent` would bypass the thing under test.
    func click(at point: NSPoint, windowNumber: Int) {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        guard let event else {
            return XCTFail("could not synthesise a mouse event at \(point)")
        }
        NSApp.sendEvent(event)
        settle()
    }
}
