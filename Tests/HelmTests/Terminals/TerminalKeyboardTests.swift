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
    func testASynthesisedKeystrokeReachesThePty() throws {
        let helm = HelmWindow(terminals: 1)
        defer { helm.close() }

        helm.expectKeyboard(on: helm.session(0).hostView)

        let pty = try helm.pty(0)
        helm.type("x")

        XCTAssertTrue(
            pty.received("x"),
            "the keystroke never reached the shell; pty saw \(pty.debugDescription)")
    }

    /// #96 as reported: ⌘N opens a tab that renders as selected, with a cursor, and swallows
    /// everything typed at it.
    func testATerminalCreatedByCommandNTakesTheKeyboard() throws {
        let helm = HelmWindow(terminals: 1)
        defer { helm.close() }

        helm.command(.newTerminal)

        XCTAssertEqual(helm.terminals.sessions.count, 2)
        helm.expectKeyboard(
            on: helm.session(1).hostView, "the new terminal did not take the keyboard")

        let arriving = try helm.pty(1)
        let existing = try helm.pty(0)
        helm.type("y")

        XCTAssertTrue(arriving.received("y"), "⌘N's terminal received nothing")
        XCTAssertFalse(
            existing.received.contains("y"), "the keystroke went to the wrong terminal")
    }

    /// ⌘1–9. The pane comes back from the same slot, so nothing is created — the other
    /// session's long-lived view is simply mounted again.
    func testATerminalSelectedByCommandNumberTakesTheKeyboard() throws {
        let helm = HelmWindow(terminals: 1)
        defer { helm.close() }

        helm.command(.newTerminal)
        helm.command(.selectTerminal(index: 0))

        helm.expectKeyboard(
            on: helm.session(0).hostView, "the selected terminal did not take the keyboard")

        let selected = try helm.pty(0)
        let other = try helm.pty(1)
        helm.type("z")

        XCTAssertTrue(selected.received("z"))
        XCTAssertFalse(other.received.contains("z"))
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

        helm.expectKeyboard(
            on: helm.view(of: focused), "the focused slot's terminal should hold the keyboard")

        let front = try helm.pty(of: focused)
        let behind = try helm.pty(of: background)
        helm.type("q")

        XCTAssertTrue(front.received("q"))
        XCTAssertFalse(behind.received.contains("q"))
    }

    /// ⌘⌥↓ moves focus to another slot without remounting anything, so there is no window
    /// change to hear — the intent flag's own edge has to carry it.
    func testMovingFocusBetweenSlotsMovesTheKeyboard() throws {
        let helm = HelmWindow(terminals: 2, layout: .twoSlots)
        defer { helm.close() }

        let first = try XCTUnwrap(helm.workbench.bench?.focusedPane?.id)

        helm.command(.moveFocus(.down))
        let second = try XCTUnwrap(helm.workbench.bench?.focusedPane?.id)
        XCTAssertNotEqual(first, second, "the bench did not move focus; the test proves nothing")

        helm.expectKeyboard(on: helm.view(of: second))
        let arriving = try helm.pty(of: second)
        helm.type("w")
        XCTAssertTrue(arriving.received("w"))
    }

    // MARK: - What the terminal must NOT do

    /// The reason the old claim was written non-stealing: it ran on every re-render, and a
    /// terminal that re-grabs focus each tick makes the chat composer and the workspace bar
    /// untypable. The claim is edge-triggered now, so a re-render that changes nothing about
    /// focus must leave another view's first responder exactly where it is.
    ///
    /// **Both halves are here on purpose.** Every assertion about not-stealing is negative,
    /// and a negative passes just as well when the mechanism was never asked at all — a
    /// redraw that failed to reach the representable would look identical to one it correctly
    /// ignored. So the test goes on to move focus for real: the terminal must then take the
    /// keyboard, which is the positive control proving the pipeline was live the whole time.
    func testARedrawDoesNotStealTheKeyboardBackButAFocusChangeStillDoes() throws {
        let helm = HelmWindow(terminals: 2, layout: .twoSlots)
        defer { helm.close() }

        let elsewhere = try XCTUnwrap(
            helm.workbench.bench?.panes.map(\.id).first {
                $0 != helm.workbench.bench?.focusedPane?.id
            })

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
        // A divider is two members, so a resize names the neighbour it trades with — the
        // rule #90 introduced. `.twoSlots` guarantees there is one, adjacent, same column.
        let neighbour = try XCTUnwrap(
            helm.workbench.bench?.slots.map(\.id).first { $0 != slot })
        helm.workbench.resizeSlot(slot, to: 0.4, against: neighbour)
        helm.settle()

        XCTAssertNotNil(
            composer.currentEditor(),
            "the terminal stole the keyboard back from a field being typed into")
        XCTAssertNotEqual(
            helm.window.firstResponder as? NSView, helm.session(0).hostView,
            "the terminal stole the keyboard back")

        // The positive control: the same machinery, asked a question it must answer.
        helm.command(.moveFocus(.down))

        helm.expectKeyboard(
            on: helm.view(of: elsewhere),
            "focus moved and no terminal took the keyboard — the redraw half proves nothing")
    }

    /// Closing the focused pane tears the current first responder out of the window in the
    /// same update that hands focus to a neighbour. `testMovingFocusBetweenSlots…` proves the
    /// edge fires when both panes stay mounted; this is the same edge racing a teardown.
    func testClosingTheFocusedPaneHandsTheKeyboardToItsNeighbour() throws {
        let helm = HelmWindow(terminals: 2)
        defer { helm.close() }

        let closing = try XCTUnwrap(helm.workbench.bench?.focusedPane?.id)
        helm.command(.closePane)

        let survivor = try XCTUnwrap(helm.workbench.bench?.focusedPane?.id)
        XCTAssertNotEqual(closing, survivor, "nothing closed; the test proves nothing")
        helm.expectKeyboard(on: helm.view(of: survivor))

        let inherited = try helm.pty(of: survivor)
        helm.type("x")
        XCTAssertTrue(inherited.received("x"))
    }

    /// Switching workspaces unmounts one workspace's panes and mounts another's — the fourth
    /// way a terminal gains a window, and the most frequent one in real use.
    func testSwitchingWorkspacesMovesTheKeyboardToTheNewBench() throws {
        let helm = HelmWindow(terminals: 1)
        defer { helm.close() }

        let arriving = helm.openAnotherWorkspace()

        helm.expectKeyboard(
            on: helm.view(of: arriving),
            "the terminal mounted by a workspace switch never took the keyboard")

        let pty = try helm.pty(of: arriving)
        helm.type("z")
        XCTAssertTrue(pty.received("z"))
    }

    /// **The chat face gives its composer the keyboard, and ⌘T gives it back to the shell.**
    ///
    /// This test used to assert the opposite — that a pane reading an agent's prose still
    /// handed the keyboard to the terminal underneath — and the reasoning was sound at the
    /// time: `ChatComposer` set `focused = true` in exactly one place, an `onChange(of:
    /// prefill)`, so a face-aware claim would have left *nothing* holding the keyboard on the
    /// chat face, which is #96 again one pane over.
    ///
    /// The premise is what changed, not the principle. #152 made the composer take the
    /// keyboard when its overlay opens, so the face-blind claim stopped being the safe option
    /// and became the bug: with the grid holding the keyboard, typing on the reading face went
    /// to the **shell**, invisible under the overlay, and the operator's sentence was executed
    /// rather than sent.
    ///
    /// **Both halves are here for the reason the redraw test gives.** "The terminal does not
    /// hold it" passes just as well if nothing holds it at all, so the second half toggles back
    /// and requires the grid to take it — which is also the `false → true` edge that would not
    /// fire if `holdsKeyboard` were still face-blind.
    func testTheChatFaceTakesTheKeyboardAndGivesItBackOnToggle() throws {
        let helm = HelmWindow(terminals: 1, layout: .oneSlotReadingChat)
        defer { helm.close() }

        Eventually.holds { helm.window.firstResponder is NSTextView }
        XCTAssertNotEqual(
            helm.window.firstResponder as? NSView, helm.session(0).hostView,
            "the grid holds the keyboard on the reading face; the composer is untypable and "
                + "everything typed reaches the shell instead")
        XCTAssertTrue(
            helm.window.firstResponder is NSTextView,
            "nothing that edits text holds the keyboard — the composer did not claim it, which "
                + "is #96 on the chat face rather than a fix for it")

        let pty = try helm.pty(0)
        helm.type("q")

        // Back to the grid: the same pane, the other face.
        helm.command(.toggleChat)

        helm.expectKeyboard(
            on: helm.session(0).hostView,
            "⌘T returned to the terminal and nothing handed the shell its keyboard back")
        helm.type("z")
        XCTAssertTrue(pty.received("z"))
        // **Checked here rather than straight after the `q`, and that is stronger, not
        // laxer.** A leaked keystroke arrives on ghostty's own schedule, so reading the pty a
        // moment after typing asks before the wrong answer could have shown up — the negative
        // passes for free on a busy machine. By the time `z` has arrived the whole pipeline has
        // demonstrably run, so a `q` that leaked is certainly here to be seen.
        XCTAssertFalse(
            pty.received.contains("q"), "a keystroke meant for the composer reached the pty")
    }

    // MARK: - The mechanism #96 turned on

    /// **The regression test proper.** The old claim hung off a `DispatchQueue.main.async`
    /// hop out of `updateNSView` and gave up silently when the view had no window yet. This
    /// reproduces exactly that: SwiftUI builds and updates the whole hierarchy *outside* any
    /// window, the hop is allowed to run and find nothing, and only then does the view get a
    /// window. Under the old code the keyboard was lost for good, with no second update
    /// coming; under `viewDidMoveToWindow` it arrives with the window.
    func testATerminalThatGainsItsWindowLateStillTakesTheKeyboard() throws {
        let helm = HelmWindow(terminals: 1, attach: .afterTheHop)
        defer { helm.close() }

        helm.expectKeyboard(
            on: helm.session(0).hostView,
            "a view put in its window after SwiftUI's update never claimed the keyboard")

        let pty = try helm.pty(0)
        helm.type("k")
        XCTAssertTrue(pty.received("k"))
    }
}

// MARK: - Harness

/// helm in a window, with readable ptys.
@MainActor
private final class HelmWindow {
    enum Layout {
        /// One column, one slot, N tabs — the frame a first-run workspace gets.
        case oneSlot
        /// The same, with the selected pane showing the agent's writing instead of the grid.
        case oneSlotReadingChat
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
    /// Every workspace this harness has activated, so `close()` can tear all of them down.
    private var openedWorkspaces: [String] = []

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
        openedWorkspaces.append(workspacePath)
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
    ///
    /// `closeWorkspace` and not just `deactivate`, for every workspace this harness opened.
    /// `WorkbenchModel.deactivate` clears the bench and by design never touches the manager's
    /// sessions — so without this, releasing the ptys depends on ARC reaching `terminals`
    /// when the harness goes out of scope. That works today and is one stray strong reference
    /// away from a live Metal layer and display link outliving its test.
    func close() {
        window.contentView = nil
        window.close()
        for path in openedWorkspaces { terminals.closeWorkspace(path) }
        workbench.deactivate()
    }

    /// Let AppKit, SwiftUI and ghostty run for a moment.
    ///
    /// **Deliberately no longer how anything is waited for.** It used to be a fixed 0.6s (0.3s
    /// after a keystroke), which is a bet that the machine is as fast today as it was when the
    /// number was picked — and #192 is that bet lost. Every claim this suite makes now waits on
    /// its own observable with a generous ceiling (`Eventually`), so this is only what it says:
    /// a chance for the hierarchy to run before a *negative* claim, which has no edge to wait
    /// for by definition.
    func settle() { Eventually.pump() }

    func session(_ index: Int) -> TerminalSession { terminals.sessions[index] }

    func pty(_ index: Int) throws -> Pty { try pty(of: session(index).id) }

    func view(of pane: Pane.ID) -> NSView? {
        terminals.sessions.first { $0.id == pane }?.hostView
    }

    /// **The keyboard is on `view` — waited for, not sampled.**
    ///
    /// Every route into a terminal taking the keyboard is asynchronous somewhere: SwiftUI's
    /// update, AppKit handing the view its window, the bench committing a focus change. Reading
    /// `firstResponder` a fixed moment later asks the question before the answer exists on any
    /// machine slower than the one the number was chosen on.
    func expectKeyboard(
        on view: NSView?, _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        Eventually.holds { self.window.firstResponder === view }
        XCTAssertEqual(window.firstResponder as? NSView, view, message(), file: file, line: line)
    }

    /// The pty behind a pane, matched on the in-memory session's **identity**.
    ///
    /// It was matched on position — the Nth session's Nth `Pty` — and that was wrong the
    /// moment a test could close a pane: `terminals.sessions` shrinks where the registry
    /// does not, so index N silently starts naming a different terminal. It failed as a
    /// missing keystroke, which reads as a focus bug and is not one.
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
        // **The one precondition every keystroke assertion in this file rests on**, checked
        // here because this accessor is the single door all of them go through. A surface that
        // never came up and a keyboard that went to the wrong pane are the same red without
        // it — see `MissingTerminalSurface`, and #192, which that ambiguity cost two days.
        let budget: TimeInterval = 5
        guard Eventually.holds(within: budget, { memory.hasSurface }) else {
            throw MissingTerminalSurface(pane: pane, waited: budget)
        }
        return pty
    }

    /// Post one of helm's commands the way the menu does, and let it land.
    func command(_ command: HelmCommand) {
        command.post()
        settle()
    }

    /// Activate a second workspace on the same bench, the way `RootView` does when the
    /// operator picks another folder. Returns the pane its terminal arrives under.
    @discardableResult
    func openAnotherWorkspace() -> Pane.ID {
        let path = workspacePath + "another/"
        let pane = UUID()
        openedWorkspaces.append(path)
        workbench.activate(
            workspacePath: path,
            restoring: Workbench(panes: [Pane(id: pane, content: .terminal(face: .terminal))]))
        settle()
        return pane
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
            // Loudly, not silently: a dropped event would surface downstream as "the
            // keystroke never reached the shell", which reads as a focus bug and is not one.
            guard let event else {
                return XCTFail("could not synthesise a key event for \(character)")
            }
            window.sendEvent(event)
        }
        // No budget for the byte's journey here — `Pty.received(_:)` waits for arrival at the
        // pty it is asked about. The short pump is for the *negative* claims only, so that
        // "it did not reach this pty" has had a fair chance to be wrong.
        settle()
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
        let face: TerminalFace = layout == .oneSlotReadingChat ? .chat : .terminal
        let panes = ids.map { Pane(id: $0, content: .terminal(face: face)) }
        switch layout {
        case .oneSlot, .oneSlotReadingChat:
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
        let drained = XCTestExpectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        XCTAssertEqual(
            XCTWaiter.wait(for: [drained], timeout: 2), .completed,
            "the main queue never drained; the late-attach ordering was not reproduced")
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
