import AppKit
import GhosttyTerminal
import SwiftUI
import XCTest

@testable import Helm

/// **Does a keystroke reach the shell.** Nothing in this suite asked that before #96, and
/// that is exactly how a terminal which accepted no input at all shipped past 435 tests and
/// seven review agents: the grid had been measured for colour, contrast and truecolor — all
/// off pixels — and never once for input.
///
/// These build the real thing: a real `NSWindow`, the real `WorkbenchView` hierarchy, the
/// real `TerminalSession` with a real ghostty surface, and `NSEvent`s pushed through
/// `NSWindow.sendEvent` so they travel the responder chain instead of being handed to a view
/// directly. What is NOT real is the pty — the sessions run on libghostty's in-memory
/// backend, so the bytes a keystroke produces arrive at a closure this file can read instead
/// of disappearing into a file descriptor. That is the only substitution, and it is the one
/// that makes the question answerable at all.
@MainActor
final class TerminalKeyboardTests: XCTestCase {
    // MARK: - The keystroke arrives

    /// The baseline the whole suite was missing: helm, one terminal, one key, does the byte
    /// come out the other side.
    func testASynthesisedKeystrokeReachesThePty() {
        let helm = HelmWindow(terminals: 1)
        defer { helm.close() }

        XCTAssertEqual(helm.window.firstResponder as? NSView, helm.session(0).hostView)

        helm.type("x")

        XCTAssertTrue(
            helm.pty(0).received.contains("x"),
            "the keystroke never reached the shell; pty saw \(helm.pty(0).debugDescription)")
    }

    /// #96 as reported: ⌘N opens a tab that renders as selected, with a cursor, and swallows
    /// everything typed at it.
    func testATerminalCreatedByCommandNTakesTheKeyboard() {
        let helm = HelmWindow(terminals: 1)
        defer { helm.close() }

        helm.command(.helmNewTerminal)

        XCTAssertEqual(helm.terminals.sessions.count, 2)
        XCTAssertEqual(
            helm.window.firstResponder as? NSView, helm.session(1).hostView,
            "the new terminal did not take the keyboard")

        helm.type("y")

        XCTAssertTrue(helm.pty(1).received.contains("y"), "⌘N's terminal received nothing")
        XCTAssertFalse(
            helm.pty(0).received.contains("y"), "the keystroke went to the wrong terminal")
    }

    /// ⌘1–9. The pane comes back from the same slot, so nothing is created — the other
    /// session's long-lived view is simply mounted again.
    func testATerminalSelectedByCommandNumberTakesTheKeyboard() {
        let helm = HelmWindow(terminals: 1)
        defer { helm.close() }

        helm.command(.helmNewTerminal)
        helm.command(.helmSelectTerminal, 0)

        XCTAssertEqual(
            helm.window.firstResponder as? NSView, helm.session(0).hostView,
            "the selected terminal did not take the keyboard")

        helm.type("z")

        XCTAssertTrue(helm.pty(0).received.contains("z"))
        XCTAssertFalse(helm.pty(1).received.contains("z"))
    }

    // MARK: - Which terminal, when there is more than one on screen

    /// A bench restored with two slots mounts two terminals at once. Exactly one of them is
    /// the focused pane, and the other must not fight it for the keyboard.
    func testOnlyTheFocusedSlotsTerminalTakesTheKeyboard() throws {
        let helm = HelmWindow(terminals: 2, layout: .twoSlots)
        defer { helm.close() }

        let focused = try XCTUnwrap(helm.workbench.bench?.focusedPane?.id)
        let background = try XCTUnwrap(
            helm.workbench.bench?.panes.map(\.id).first { $0 != focused })

        XCTAssertEqual(
            helm.window.firstResponder as? NSView, helm.view(of: focused),
            "the focused slot's terminal should hold the keyboard")

        helm.type("q")

        XCTAssertTrue(try helm.pty(of: focused).received.contains("q"))
        XCTAssertFalse(try helm.pty(of: background).received.contains("q"))
    }

    /// ⌘⌥↓ moves focus to another slot without remounting anything, so there is no window
    /// change to hear — the intent flag's own edge has to carry it.
    func testMovingFocusBetweenSlotsMovesTheKeyboard() throws {
        let helm = HelmWindow(terminals: 2, layout: .twoSlots)
        defer { helm.close() }

        let first = try XCTUnwrap(helm.workbench.bench?.focusedPane?.id)

        helm.command(.helmMoveFocus, Workbench.Direction.down.rawValue)
        let second = try XCTUnwrap(helm.workbench.bench?.focusedPane?.id)
        XCTAssertNotEqual(first, second, "the bench did not move focus; the test proves nothing")

        XCTAssertEqual(helm.window.firstResponder as? NSView, helm.view(of: second))
        helm.type("w")
        XCTAssertTrue(try helm.pty(of: second).received.contains("w"))
    }

    // MARK: - What the terminal must NOT do

    /// The reason the old claim was written non-stealing: it ran on every re-render, and a
    /// terminal that re-grabs focus each tick makes the chat composer and the workspace bar
    /// untypable. The claim is edge-triggered now, so a re-render that changes nothing about
    /// focus must leave another view's first responder exactly where it is.
    func testARedrawDoesNotStealTheKeyboardBack() throws {
        let helm = HelmWindow(terminals: 1)
        defer { helm.close() }

        // A text field rather than a bare view, because the thing being protected is the
        // chat composer. Note what holds first responder afterwards is the window's FIELD
        // EDITOR, not the field — so "is the field still being edited" is the question, and
        // `currentEditor()` is how AppKit answers it.
        let composer = NSTextField(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        helm.window.contentView?.addSubview(composer)
        XCTAssertTrue(helm.window.makeFirstResponder(composer))
        XCTAssertNotNil(composer.currentEditor(), "the field never took the keyboard")

        // A bench change that does not move focus — the same shape as any poll-driven
        // re-render, and the one the old implementation had to defend against.
        let slot = try XCTUnwrap(helm.workbench.bench?.focusedSlot)
        helm.workbench.resizeSlot(slot, to: 0.4)
        helm.settle()

        XCTAssertNotNil(
            composer.currentEditor(),
            "the terminal stole the keyboard back from a field being typed into")
        XCTAssertNotEqual(
            helm.window.firstResponder as? NSView, helm.session(0).hostView,
            "the terminal stole the keyboard back")
    }

    // MARK: - The mechanism #96 turned on

    /// **The regression test proper.** The old claim hung off a `DispatchQueue.main.async`
    /// hop out of `updateNSView` and gave up silently when the view had no window yet. This
    /// reproduces exactly that: SwiftUI builds and updates the whole hierarchy *outside* any
    /// window, the hop is allowed to run and find nothing, and only then does the view get a
    /// window. Under the old code the keyboard was lost for good, with no second update
    /// coming; under `viewDidMoveToWindow` it arrives with the window.
    func testATerminalThatGainsItsWindowLateStillTakesTheKeyboard() {
        let helm = HelmWindow(terminals: 1, attach: .afterTheHop)
        defer { helm.close() }

        XCTAssertEqual(
            helm.window.firstResponder as? NSView, helm.session(0).hostView,
            "a view put in its window after SwiftUI's update never claimed the keyboard")

        helm.type("k")
        XCTAssertTrue(helm.pty(0).received.contains("k"))
    }
}

// MARK: - Harness

/// helm in a window, with readable ptys.
@MainActor
private final class HelmWindow {
    enum Layout {
        /// One column, one slot, N tabs — the frame a first-run workspace gets.
        case oneSlot
        /// Two slots stacked in one column, one terminal each: two panes on screen at once,
        /// which is the state a single app-level "selected terminal" could never express.
        case twoSlots
    }

    /// When the hosting view is put into the window, relative to SwiftUI's first update.
    enum Attach {
        /// Straight away, which is what a launching app does.
        case immediately
        /// After the first update AND a drained main queue — the ⌘N ordering that #96 is.
        case afterTheHop
    }

    let terminals: TerminalManager
    let workbench: WorkbenchModel
    let window: NSWindow
    private let ptys = PtyRegistry()
    private let workspacePath = NSTemporaryDirectory()

    init(terminals count: Int, layout: Layout = .oneSlot, attach: Attach = .immediately) {
        // A test bundle is not an app, and AppKit will not deliver a key event through a
        // window that belongs to no application. `.accessory` keeps it out of the Dock and
        // off the operator's screen — nothing here activates, so nothing steals their focus.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let registry = ptys
        terminals = TerminalManager(backend: { registry.next() })
        workbench = WorkbenchModel(terminals: terminals)

        // Restore rather than open, so the ids are known before anything mounts — which is
        // also the launch path, and one of the three cases #96 lists.
        let ids = (0..<count).map { _ in UUID() }
        workbench.activate(workspacePath: workspacePath, restoring: Self.bench(ids, layout))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false

        let hosting = NSHostingView(
            rootView: WorkbenchView(model: workbench, workspaceRoot: workspacePath))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

        switch attach {
        case .immediately:
            window.contentView = hosting
        case .afterTheHop:
            // Lay the whole tree out with no window anywhere in it, then let the main queue
            // drain. Any claim that depends on `view.window` being non-nil during SwiftUI's
            // update, or one runloop turn after it, has now had its chance and missed.
            hosting.layoutSubtreeIfNeeded()
            Self.drainMainQueue()
            window.contentView = hosting
        }
        settle()
    }

    /// Explicit rather than a `deinit`: a nonisolated deinit may not touch main-actor state,
    /// and leaving the window in the run loop leaks a Metal-backed surface into the next test.
    func close() {
        window.contentView = nil
        window.close()
        workbench.deactivate()
    }

    /// Let AppKit, SwiftUI and ghostty catch up. Surfaces spawn on attach and the wrapper
    /// ticks the runtime off a display link, so this is a real wait rather than a hop.
    func settle(_ seconds: TimeInterval = 0.6) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    func session(_ index: Int) -> TerminalSession { terminals.sessions[index] }

    func pty(_ index: Int) -> Pty { ptys.all[index] }

    func view(of pane: Pane.ID) -> NSView? {
        terminals.sessions.first { $0.id == pane }?.hostView
    }

    func pty(of pane: Pane.ID) throws -> Pty {
        let index = try XCTUnwrap(terminals.sessions.firstIndex { $0.id == pane })
        return ptys.all[index]
    }

    /// Post one of helm's commands the way the menu does, and let it land.
    func command(_ name: Notification.Name, _ object: Any? = nil) {
        NotificationCenter.default.post(name: name, object: object)
        settle()
    }

    /// A keystroke through the window, not into a view: `sendEvent` walks the responder
    /// chain, so this asks the question the operator asks — where does typing go.
    func type(_ text: String) {
        for character in text {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: String(character), charactersIgnoringModifiers: String(character),
                isARepeat: false, keyCode: Self.keyCode(for: character))
            if let event { window.sendEvent(event) }
        }
        settle(0.3)
    }

    /// ANSI US virtual key codes for the handful of letters these tests type. ghostty
    /// translates the physical key, so a wrong code produces a wrong byte rather than none.
    private static func keyCode(for character: Character) -> UInt16 {
        let codes: [Character: UInt16] = [
            "k": 40, "q": 12, "w": 13, "x": 7, "y": 16, "z": 6,
        ]
        return codes[character] ?? 0
    }

    private static func bench(_ ids: [UUID], _ layout: Layout) -> Workbench {
        let panes = ids.map { Pane(id: $0, content: .terminal(face: .terminal)) }
        switch layout {
        case .oneSlot:
            return Workbench(panes: panes)
        case .twoSlots:
            var bench = Workbench(panes: [panes[0]])
            for pane in panes.dropFirst() { bench.splitDown(with: pane) }
            // `splitDown` leaves focus on the new slot; put it back on the first, so
            // "focused" and "mounted first" are different answers and the test can tell
            // them apart.
            bench.focus(bench.slots[0].id)
            return bench
        }
    }

    /// Run the main queue until a block posted *now* has come back round, so anything the
    /// hierarchy scheduled during layout has already run.
    private static func drainMainQueue() {
        let drained = Flag()
        DispatchQueue.main.async { drained.raise() }
        let deadline = Date().addingTimeInterval(2)
        while !drained.isRaised, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private final class Flag {
        private(set) var isRaised = false
        func raise() { isRaised = true }
    }
}

// MARK: - Ptys

/// The host side of one in-memory surface: everything the terminal has written toward its
/// shell. For an exec surface these same bytes go into a pty file descriptor.
final class Pty: @unchecked Sendable, CustomDebugStringConvertible {
    private let lock = NSLock()
    private var bytes = Data()

    /// Retained because `TerminalSurfaceOptions` is the only other owner and a test wants to
    /// outlive a session teardown.
    private(set) var session: InMemoryTerminalSession!

    init() {
        session = InMemoryTerminalSession(
            write: { [weak self] data in self?.append(data) },
            resize: { _ in }
        )
    }

    var received: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    var debugDescription: String {
        let text = received
        return text.isEmpty ? "<nothing>" : String(reflecting: text)
    }

    private func append(_ data: Data) {
        lock.lock()
        bytes.append(data)
        lock.unlock()
    }
}

/// One `Pty` per session, in creation order — which is `TerminalManager.sessions` order.
@MainActor
private final class PtyRegistry {
    private(set) var all: [Pty] = []

    func next() -> TerminalSessionBackend {
        let pty = Pty()
        all.append(pty)
        return .inMemory(pty.session)
    }
}
