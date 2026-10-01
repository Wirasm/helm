import AppKit
import GhosttyTerminal
import HelmWire
import SwiftUI
import XCTest

@testable import Helm

/// helm in a real window, with readable ptys: the half of a window-driving suite that stands
/// the window up. A suite subclasses it and keeps what is its own question —
/// `TerminalKeyboardTests`' layouts and late attach, `WorkbenchFocusRoutingTests`' clicks.
///
/// A real `NSWindow` around a real `WorkbenchView` hierarchy drawn from a toy benchd
/// (`ToyBench`), with real `TerminalSession`s whose surfaces run a `Pty` recorder instead of a
/// login shell.
@MainActor
class WindowHarness {
    let terminals: TerminalManager
    let workbench: WorkbenchModel
    let window: NSWindow
    let workspacePath: String
    private let ptys: PtyRegistry
    /// The toy benchd the bench is drawn from (`ToyBench`), and helm's client for it.
    private let server: FakeBenchd
    private let client: BenchClient

    /// Draws `bench` in `workspacePath`, hosting `root` in the window. `beforeAttach` runs on
    /// the hosting view after it is built and before it is put in the window.
    init<Root: View>(
        bench: BenchDocument.Bench, workspacePath: String,
        root: (WorkbenchModel) -> Root, beforeAttach: (NSView) -> Void = { _ in }
    ) throws {
        // A test bundle is not an app, and AppKit will not deliver a key event through a
        // window that belongs to no application. `.accessory` keeps it out of the Dock and
        // off the operator's screen — nothing here activates, so nothing steals their focus.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        self.workspacePath = workspacePath
        // The command closure is handed to `TerminalManager` before `self` exists, so it
        // captures the registry rather than `self`.
        let registry = PtyRegistry()
        ptys = registry
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
        beforeAttach(hosting)
        window.contentView = hosting
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
        // up and a keyboard that went to the wrong pane are the same red without it — see
        // `MissingTerminalSurface`, and #192, which that ambiguity cost two days.
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

    /// Carry out one of the key table's gestures the way a key does — resolved against the
    /// bench and sent as the operator — and let it land.
    func command(_ gesture: VerbTemplate) {
        if let verb = gesture.resolve(bench: workbench.bench, workspaces: [], active: nil) {
            workbench.send(verb, by: .operatorGesture)
        }
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
    /// physical key, so a wrong code produces a wrong byte rather than none — which surfaces as
    /// "the terminal received nothing", reading as a focus bug when it is a typo. Unknown
    /// characters fail here rather than defaulting to a code that happens to mean `a`.
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

// MARK: - Ptys

/// The program side of one test surface: every byte the terminal wrote toward it.
///
/// Each test surface runs this recorder instead of a login shell. It puts its tty in raw mode,
/// so a keystroke arrives as its own bytes instead of waiting for a line, marks itself ready,
/// and copies everything it reads into a file this object reads back. A real pty, the same
/// exec path the operator's panes take — nothing in the wrapper is faked for the test.
final class Pty: CustomDebugStringConvertible {
    private let directory: URL
    /// What the surface runs. Also this recorder's identity: `pty(of:)` matches a session to
    /// its recorder by the command its surface was configured with.
    let command: String

    init() {
        _ = Self.sweptOnce
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-pty-\(getpid())-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("record")
        let body = """
            #!/bin/sh
            stty raw -echo
            : > '\(directory.path)/ready'
            exec cat > '\(directory.path)/received'
            """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: script.path)
        command = script.path
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A run that crashed or was killed never reaches `deinit`, so the first recorder of each run
    /// removes the ones left by runs whose process is gone. The pid in the name is the owner: a
    /// suite running in another worktree keeps its recorders.
    private static let sweptOnce: Void = {
        let temporary = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix("helm-pty-") {
            let owner = name.dropFirst("helm-pty-".count).split(separator: "-").first
            guard let pid = owner.flatMap({ pid_t($0) }), kill(pid, 0) != 0, errno == ESRCH
            else { continue }
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
    }()

    /// The recorder is running with its tty in raw mode. A keystroke typed before this can
    /// sit in the line discipline's canonical buffer and never reach `cat`.
    var isReady: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path)
    }

    var received: String {
        let data = (try? Data(contentsOf: directory.appendingPathComponent("received"))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    var debugDescription: String {
        let text = received
        return text.isEmpty ? "<nothing>" : String(reflecting: text)
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
