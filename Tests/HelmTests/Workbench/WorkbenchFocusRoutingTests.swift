import AppKit
import GhosttyTerminal
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
        let bench = Bench(terminals: 2)
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
        let bench = Bench(terminals: 2)
        defer { bench.close() }

        let first = try XCTUnwrap(bench.workbench.bench?.slots.first?.id)
        let second = try XCTUnwrap(bench.workbench.bench?.slots.last?.id)
        XCTAssertEqual(
            bench.workbench.bench?.focusedSlot, first, "the fixture should start on the first slot")

        try bench.clickPane(inSlot: second)
        Eventually.holds { bench.workbench.bench?.focusedSlot == second }
        bench.command(.helmSplitDown)

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

    /// ⌘T with focus resting on another pane returns silently — the guard in `toggleFace` is
    /// correct, and the operator's evidence for *which pane is focused* is the cursor.
    func testToggleFaceAfterAClickTogglesTheClickedPane() throws {
        let bench = Bench(terminals: 2)
        defer { bench.close() }

        let untouched = try XCTUnwrap(bench.workbench.bench?.focusedPane?.id)
        let clicked = try XCTUnwrap(
            bench.workbench.bench?.panes.map(\.id).first { $0 != untouched })

        try bench.clickPane(inSlot: try bench.slot(holding: clicked))
        Eventually.holds { bench.workbench.bench?.focusedPane?.id == clicked }
        bench.command(.helmToggleChat)

        Eventually.holds { bench.workbench.bench?.pane(clicked)?.content == .terminal(face: .chat) }
        XCTAssertEqual(
            bench.workbench.bench?.pane(clicked)?.content, .terminal(face: .chat),
            "⌘T did not reach the pane that was clicked")
        XCTAssertEqual(
            bench.workbench.bench?.pane(untouched)?.content, .terminal(face: .terminal),
            "⌘T toggled the pane the operator was not looking at")
    }

    /// The loop closed end to end: the click moves the bench, the bench hands the grid the
    /// keyboard, and the keystroke comes out of that pane's pty. This is also the only
    /// assertion here that would fail if the monitor ever started **consuming** the click.
    func testTypingAfterAClickReachesTheClickedTerminal() throws {
        let bench = Bench(terminals: 2)
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
    /// runs `reconcileVisibility` and drives the save to `UserDefaults`, so an unguarded
    /// `focus` would persist the whole workspace context on every click in the pane you are
    /// typing in.
    func testClickingTheAlreadyFocusedPaneRewritesNothing() throws {
        let bench = Bench(terminals: 2)
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
        let bench = Bench(terminals: 2)
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
        let bench = Bench(terminals: 2)
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

    // MARK: - The menu's route

    /// View ▸ Focus Left/Right/Up/Down were silent no-ops: the menu posted `payload`, which is
    /// nil on every row that carries a direction. Both consumers go through `Shortcut.post()`
    /// now, so this asks the table itself the question the menu used to get wrong.
    func testEveryFocusRowPostsItsDirectionThroughTheOneSeam() throws {
        let rows = Shortcut.all.filter { $0.direction != nil }
        XCTAssertEqual(rows.count, 4, "the four ⌘⌥arrow rows are the ones carrying a direction")

        for row in rows {
            XCTAssertNotNil(row.menu, "a focus row that is not in the menu cannot be clicked")
            XCTAssertNil(
                row.payload,
                "\(row.menu!.title) carries its direction in `direction`; a non-nil payload "
                    + "would mean the two fields disagree")

            var delivered: Any?
            let token = NotificationCenter.default.addObserver(
                forName: row.notification, object: nil, queue: nil
            ) { delivered = $0.object }
            defer { NotificationCenter.default.removeObserver(token) }

            row.post()

            XCTAssertEqual(
                delivered as? String, row.direction?.rawValue,
                "\(row.menu!.title) posted \(String(describing: delivered)) — the subscriber "
                    + "requires the direction's raw value and drops anything else")
        }
    }

    /// The end of it: the menu's route moves focus on a real bench, which is the acceptance
    /// criterion no unit test on the table alone can reach.
    func testTheMenusFocusRowMovesFocusOnARealBench() throws {
        let bench = Bench(terminals: 2)
        defer { bench.close() }

        let before = try XCTUnwrap(bench.workbench.bench?.focusedSlot)
        let row = try XCTUnwrap(Shortcut.all.first { $0.direction == .down })

        row.post()
        Eventually.holds { bench.workbench.bench?.focusedSlot != before }

        XCTAssertNotEqual(
            bench.workbench.bench?.focusedSlot, before,
            "View ▸ Focus Down did nothing — the menu is posting something the subscriber drops")
    }
}

// MARK: - Harness

/// helm in a window, with two stacked slots and readable ptys.
///
/// Deliberately its own harness rather than `TerminalKeyboardTests`' — that one is private to
/// its file, and the file holds the one test #152 must leave untouched. Reaching into it to
/// share a fixture would mean editing exactly the file whose stability is the constraint.
@MainActor
private final class Bench {
    let terminals: TerminalManager
    let workbench: WorkbenchModel
    let window: NSWindow
    private let ptys = Registry()
    private let workspacePath = NSTemporaryDirectory() + "focus-routing/"

    /// The backend closure is handed to `TerminalManager` during this object's own `init`, so
    /// it cannot capture `self`. One `Pty` per session, in creation order.
    @MainActor
    final class Registry {
        private(set) var all: [Pty] = []

        func next() -> TerminalSessionBackend {
            let pty = Pty()
            all.append(pty)
            return .inMemory(pty.session)
        }
    }

    init(terminals count: Int) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let registry = ptys
        terminals = TerminalManager(backend: { registry.next() })
        workbench = WorkbenchModel(terminals: terminals)

        let ids = (0..<count).map { _ in UUID() }
        workbench.activate(workspacePath: workspacePath, restoring: Self.stacked(ids))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false

        let hosting = NSHostingView(
            rootView: WorkbenchView(model: workbench, workspaceRoot: workspacePath))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = hosting
        settle()
    }

    func close() {
        window.contentView = nil
        window.close()
        terminals.closeWorkspace(workspacePath)
        workbench.deactivate()
    }

    /// Let AppKit, SwiftUI and ghostty run for a moment.
    ///
    /// **Not how anything is waited for** — see the same note on `TerminalKeyboardTests`'
    /// harness. The fixed 0.6s this used to be is what #192 turned out to be measuring instead
    /// of what it meant to measure; claims wait on their own observable now.
    func settle() { Eventually.pump() }

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

    /// A keystroke through the window, so it travels the responder chain — the question the
    /// operator asks is *where does typing go*.
    func type(_ text: String) {
        for character in text {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: String(character), charactersIgnoringModifiers: String(character),
                isARepeat: false, keyCode: Self.keyCode(for: character))
            guard let event else {
                return XCTFail("could not synthesise a key event for \(character)")
            }
            window.sendEvent(event)
        }
        // The byte's journey is waited for at the pty, by `Pty.received(_:)`, not budgeted here.
        settle()
    }

    /// ANSI US virtual key codes. ghostty translates the physical key, so a wrong code
    /// produces a wrong byte rather than none — which would surface as "the clicked terminal
    /// received nothing", reading as a focus bug when it is a typo. Unknown characters fail
    /// here rather than defaulting to a code that happens to mean `a`.
    private static func keyCode(for character: Character) -> UInt16 {
        let codes: [Character: UInt16] = ["x": 7, "z": 6]
        guard let code = codes[character] else {
            XCTFail("no key code for \(character) — add it rather than sending a wrong one")
            return 0
        }
        return code
    }

    func command(_ name: Notification.Name, _ object: Any? = nil) {
        NotificationCenter.default.post(name: name, object: object)
        settle()
    }

    func pty(of pane: Pane.ID) throws -> Pty {
        let session = try XCTUnwrap(
            terminals.sessions.first { $0.id == pane }, "no session for pane \(pane)")
        let backend: InMemoryTerminalSession? =
            if case let .inMemory(memory) = session.hostView.configuration.backend {
                memory
            } else {
                nil
            }
        let memory = try XCTUnwrap(backend, "session \(pane) is not on an in-memory backend")
        let pty = try XCTUnwrap(
            ptys.all.first { $0.session === memory }, "no pty registered for \(pane)")
        // The surface is the precondition for the one test here that types. Without this, a
        // ghostty that refused to build a surface reads as "the click did not route" — the
        // #192 ambiguity, one suite over.
        let budget: TimeInterval = 5
        guard Eventually.holds(within: budget, { memory.hasSurface }) else {
            throw MissingTerminalSurface(pane: pane, waited: budget)
        }
        return pty
    }

    /// Two slots stacked in one column, focus put back on the first — so "focused" and "mounted
    /// first" are different answers and a test can tell a click from a coincidence.
    private static func stacked(_ ids: [UUID]) -> Workbench {
        var bench = Workbench(panes: [Pane(id: ids[0], content: .terminal(face: .terminal))])
        for id in ids.dropFirst() {
            bench.splitDown(with: Pane(id: id, content: .terminal(face: .terminal)))
        }
        bench.focus(bench.slots[0].id)
        return bench
    }
}
