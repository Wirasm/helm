import AppKit
import GhosttyTerminal
import HelmWire
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
        let helm = try HelmWindow(terminals: 1)
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
        let helm = try HelmWindow(terminals: 1)
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
        let helm = try HelmWindow(terminals: 1)
        defer { helm.close() }

        helm.command(.newTerminal)
        helm.command(.showTab(index: 0))

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
        let helm = try HelmWindow(terminals: 2, layout: .twoSlots)
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
        let helm = try HelmWindow(terminals: 2, layout: .twoSlots)
        defer { helm.close() }

        let first = try XCTUnwrap(helm.workbench.bench?.focusedPane?.id)

        helm.command(.stepFocus(.down))
        let second = try XCTUnwrap(helm.workbench.bench?.focusedPane?.id)
        XCTAssertNotEqual(first, second, "the bench did not move focus; the test proves nothing")

        helm.expectKeyboard(on: helm.view(of: second))
        let arriving = try helm.pty(of: second)
        helm.type("w")
        XCTAssertTrue(arriving.received("w"))
    }

    // MARK: - What the terminal must NOT do

    /// The reason the old claim was written non-stealing: it ran on every re-render, and a
    /// terminal that re-grabs focus each tick makes the workspace bar and a canvas's comment
    /// field untypable. The claim is edge-triggered now, so a re-render that changes nothing about
    /// focus must leave another view's first responder exactly where it is.
    ///
    /// **Both halves are here on purpose.** Every assertion about not-stealing is negative,
    /// and a negative passes just as well when the mechanism was never asked at all — a
    /// redraw that failed to reach the representable would look identical to one it correctly
    /// ignored. So the test goes on to move focus for real: the terminal must then take the
    /// keyboard, which is the positive control proving the pipeline was live the whole time.
    func testARedrawDoesNotStealTheKeyboardBackButAFocusChangeStillDoes() throws {
        let helm = try HelmWindow(terminals: 2, layout: .twoSlots)
        defer { helm.close() }

        let elsewhere = try XCTUnwrap(
            helm.workbench.bench?.panes.map(\.id).first {
                $0 != helm.workbench.bench?.focusedPane?.id
            })

        // A text field rather than a bare view, because the thing being protected is a
        // text field. Note what holds first responder afterwards is the window's FIELD
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
        helm.command(.stepFocus(.down))

        helm.expectKeyboard(
            on: helm.view(of: elsewhere),
            "focus moved and no terminal took the keyboard — the redraw half proves nothing")
    }

    /// Closing the focused pane tears the current first responder out of the window in the
    /// same update that hands focus to a neighbour. `testMovingFocusBetweenSlots…` proves the
    /// edge fires when both panes stay mounted; this is the same edge racing a teardown.
    func testClosingTheFocusedPaneHandsTheKeyboardToItsNeighbour() throws {
        let helm = try HelmWindow(terminals: 2)
        defer { helm.close() }

        let closing = try XCTUnwrap(helm.workbench.bench?.focusedPane?.id)
        helm.command(.closeFocused)

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
        let helm = try HelmWindow(terminals: 1)
        defer { helm.close() }

        let arriving = try helm.openAnotherWorkspace()

        helm.expectKeyboard(
            on: helm.view(of: arriving),
            "the terminal mounted by a workspace switch never took the keyboard")

        let pty = try helm.pty(of: arriving)
        helm.type("z")
        XCTAssertTrue(pty.received("z"))
    }

    // MARK: - The mechanism #96 turned on

    /// **The regression test proper.** The old claim hung off a `DispatchQueue.main.async`
    /// hop out of `updateNSView` and gave up silently when the view had no window yet. This
    /// reproduces exactly that: SwiftUI builds and updates the whole hierarchy *outside* any
    /// window, the hop is allowed to run and find nothing, and only then does the view get a
    /// window. Under the old code the keyboard was lost for good, with no second update
    /// coming; under `viewDidMoveToWindow` it arrives with the window.
    func testATerminalThatGainsItsWindowLateStillTakesTheKeyboard() throws {
        let helm = try HelmWindow(terminals: 1, attach: .afterTheHop)
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

/// helm in a window, with readable ptys — `HostedWorkbench`, laid out and attached the ways #96
/// turned on.
@MainActor
private final class HelmWindow: HostedWorkbench {
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

    init(terminals count: Int, layout: Layout = .oneSlot, attach: Attach = .immediately) throws {
        // Drawn from a document that already names the panes, so the ids are known before
        // anything mounts — which is also the launch path, and one of the three cases #96 lists.
        let ids = (0..<count).map { _ in UUID() }
        try super.init(
            bench: Self.bench(ids, layout), workspacePath: NSTemporaryDirectory(),
            rootView: { WorkbenchView(model: $0, workspaceRoot: $1) },
            beforeAttach: { hosting in
                guard attach == .afterTheHop else { return }
                // Lay the whole tree out with no window anywhere in it, then let the main queue
                // drain. Any claim that depends on `view.window` being non-nil during SwiftUI's
                // update, or one runloop turn after it, has now had its chance and missed.
                hosting.layoutSubtreeIfNeeded()
                Self.drainMainQueue()
            })
    }

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

    /// Open a second workspace, the way the operator's ⌘⇧O does. Returns the pane its terminal
    /// arrives under.
    @discardableResult
    func openAnotherWorkspace() throws -> Pane.ID {
        workbench.send(.workspaceOpen(path: workspacePath + "another/"), by: .operatorGesture)
        settle()
        return try XCTUnwrap(workbench.bench?.panes.first?.id)
    }

    private static func bench(_ ids: [UUID], _ layout: Layout) -> BenchDocument.Bench {
        let panes = ids.map { ToyBench.terminal($0) }
        switch layout {
        case .oneSlot:
            return ToyBench.bench(panes)
        case .twoSlots:
            // Stacked, with focus on the first, so "focused" and "mounted first" are different
            // answers and the test can tell them apart.
            let slots = panes.map {
                BenchDocument.Slot(
                    id: UUID(), panes: [$0], selected: $0.id, height: 1 / Double(panes.count))
            }
            return .init(
                columns: [.init(id: UUID(), slots: slots, width: 1)], focusedSlot: slots[0].id)
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
