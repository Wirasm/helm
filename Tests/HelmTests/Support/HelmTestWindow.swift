import AppKit
import HelmWire
import SwiftUI
import XCTest

@testable import Helm

/// helm in a real window, with readable ptys: a real `NSWindow` around a real `WorkbenchView`,
/// drawn from a toy benchd (`ToyBench`), over a `TerminalManager` whose sessions each run a
/// `Pty` recorder.
///
/// The half of a window suite that stands the window up. `TerminalKeyboardTests`' `HelmWindow`
/// and `WorkbenchFocusRoutingTests`' `Bench` subclass it and add the half that asks their own
/// question; a fix to anything here reaches both.
@MainActor
class HelmTestWindow {
    let terminals: TerminalManager
    let workbench: WorkbenchModel
    let window: NSWindow
    let workspacePath: String
    private let ptys = PtyRegistry()
    /// The toy benchd the bench is drawn from, and helm's client for it.
    private let server: FakeBenchd
    private let client: BenchClient

    /// Draws `bench` in `workspacePath` inside `root`, which is given the model. `attach` puts
    /// the hosting view into the window; by default straight away, which is what a launching
    /// app does.
    init<Root: View>(
        workspacePath: String, bench: BenchDocument.Bench,
        root: (WorkbenchModel) -> Root,
        attach: (NSWindow, NSView) -> Void = { window, hosting in window.contentView = hosting }
    ) throws {
        // A test bundle is not an app, and AppKit will not deliver a key event through a
        // window that belongs to no application. `.accessory` keeps it out of the Dock and
        // off the operator's screen — nothing here activates, so nothing steals their focus.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        self.workspacePath = workspacePath
        // The command closure is handed to `TerminalManager` before `self` exists, so it
        // captures the registry rather than `self`.
        let registry = ptys
        terminals = TerminalManager(command: { registry.next() })
        (server, client) = try startToyBenchd(.only(workspacePath, bench))
        let workbench = WorkbenchModel(terminals: terminals, client: client)
        self.workbench = workbench
        XCTAssertNotNil(client.document(atLeast: 1, within: 5), "benchd never answered")
        XCTAssertNotNil(workbench.bench, "no bench was drawn")

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: root(workbench))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        attach(window, hosting)
        settle()
    }

    /// Explicit rather than a `deinit`: a nonisolated deinit may not touch main-actor state,
    /// and leaving the window in the run loop leaks a Metal-backed surface into the next test.
    ///
    /// Every session is closed through the registry rather than left to ARC reaching
    /// `terminals` when the harness goes out of scope: that is one stray strong reference away
    /// from a live Metal layer and display link outliving its test.
    func close() {
        window.contentView = nil
        window.close()
        for session in terminals.sessions { terminals.surfaces.close(session.id) }
        client.stop()
        server.stop()
    }

    /// Let AppKit, SwiftUI and ghostty run for a moment.
    ///
    /// **Deliberately no longer how anything is waited for.** It used to be a fixed 0.6s (0.3s
    /// after a keystroke), which is a bet that the machine is as fast today as it was when the
    /// number was picked — and #192 is that bet lost. Every claim these suites make now waits
    /// on its own observable with a generous ceiling (`Eventually`), so this is only what it
    /// says: a chance for the hierarchy to run before a *negative* claim, which has no edge to
    /// wait for by definition.
    func settle() { Eventually.pump() }

    /// Carry out one of the key table's gestures the way a key does — resolved against the
    /// bench and sent as the operator — and let it land.
    func command(_ gesture: VerbTemplate) {
        if let verb = gesture.resolve(bench: workbench.bench, workspaces: [], active: nil) {
            workbench.send(verb, by: .operatorGesture)
        }
        settle()
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
        let pty = try XCTUnwrap(
            ptys.all.first { $0.command == session.hostView.configuration.command },
            "no pty registered for \(pane)")
        // **The one precondition every keystroke assertion rests on**, checked here because
        // this accessor is the single door all of them go through. A surface that never came
        // up and a keyboard (or a click) that went to the wrong pane are the same red without
        // it — see `MissingTerminalSurface`, and #192, which that ambiguity cost two days.
        let budget: TimeInterval = 5
        guard Eventually.holds(within: budget, { session.status == .running }) else {
            throw MissingTerminalSurface(pane: pane, waited: budget)
        }
        // The surface is up; the recorder in it must also be in raw mode before anything is
        // typed at it, or the keystroke waits in the line discipline for a newline.
        guard Eventually.holds(within: budget, { pty.isReady }) else {
            throw RecorderNeverStarted(pane: pane, pty: pty, waited: budget)
        }
        return pty
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

    /// ANSI US virtual key codes for the letters these tests type. ghostty translates the
    /// physical key, so a wrong code produces a wrong byte rather than none — which would
    /// surface as "the terminal received nothing", reading as a focus bug when it is a typo.
    /// Unknown characters fail here rather than defaulting to a code that happens to mean `a`.
    private static func keyCode(for character: Character) -> UInt16 {
        let codes: [Character: UInt16] = [
            "k": 40, "q": 12, "w": 13, "x": 7, "y": 16, "z": 6,
        ]
        guard let code = codes[character] else {
            XCTFail("no key code for \(character) — add it rather than sending a wrong one")
            return 0
        }
        return code
    }
}

/// One `Pty` per session, in creation order — which is `TerminalManager.sessions` order.
@MainActor
private final class PtyRegistry {
    private(set) var all: [Pty] = []

    func next() -> String? {
        let pty = Pty()
        all.append(pty)
        return pty.command
    }
}
