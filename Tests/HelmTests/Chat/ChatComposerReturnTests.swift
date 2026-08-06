import AppKit
import SwiftUI
import XCTest

@testable import Helm

/// **What a Return in the composer does — asked of a real key event, not of a function.**
///
/// `PtyTextTests` covers everything *after* helm has decided to send: two writes, the gap,
/// the escaping. Nothing covered the decision itself, and #119's third part is exactly
/// there — Enter sends, Shift+Enter starts a new line. That distinction cannot be made by
/// any function this suite could call directly, because it is AppKit that decides what a
/// Return means: `StandardKeyBinding.dict` maps `\r` to `insertNewline:` and `~\r`
/// (Option-Return) to `insertNewlineIgnoringFieldEditor:`, and **it has no entry for
/// Shift-Return at all** — shift does not change the character, so a shifted Return is an
/// ordinary one and SwiftUI's `.onSubmit` fires. That is the defect, and asserting it needs
/// the event.
///
/// So these build a real `NSWindow` around the real `ChatComposer` and push real
/// `NSEvent`s through `NSWindow.sendEvent`, the same way `TerminalKeyboardTests` does —
/// the responder chain is the thing under test. **No ghostty surface is involved**, which
/// is deliberate: a composer needs a text field and a window, not a terminal, so this suite
/// keeps working on a machine where every display is asleep and `ghostty_surface_new`
/// refuses (#253).
@MainActor
final class ChatComposerReturnTests: XCTestCase {
    /// **A control: it passes either way.** It cannot fail unless the fix overshoots and
    /// takes plain Return with it — which is the one way this change could break the
    /// composer outright, and the reason a test that only proves Shift+Return stopped
    /// sending would be satisfied by a composer that never sends at all.
    func testReturnSendsTheDraft() {
        let composer = ComposerWindow()
        defer { composer.close() }

        composer.offer("hello")
        composer.pressReturn()

        XCTAssertEqual(composer.sent, ["hello"], "Enter no longer sends")
    }

    /// **Shift+Enter starts a new line and sends nothing.**
    ///
    /// Both halves matter. "Nothing was sent" alone is satisfied by a Shift+Return that is
    /// swallowed whole, which would be a different bug wearing the same green — so the
    /// second Return is what proves the newline is really in the draft: it comes back in
    /// the message helm hands to the pty.
    func testShiftReturnStartsANewLineAndSendsNothing() {
        let composer = ComposerWindow()
        defer { composer.close() }

        composer.offer("hello")
        composer.pressReturn(shift: true)

        XCTAssertEqual(
            composer.sent, [],
            "Shift+Enter submitted the draft — the message is gone from the composer and the "
                + "operator gets no second line")

        composer.pressReturn()
        XCTAssertEqual(
            composer.sent, ["hello\n"],
            "the draft that was finally sent carries no newline, so Shift+Enter inserted "
                + "nothing")
    }

    /// A multi-line draft assembled with Shift+Enter still reaches the pty as **one**
    /// message — the property `PtyTextTests.testAMultiLineDraftIsStillOneMessage` asserts
    /// from the write side, met here from the keyboard side.
    func testALineBuiltWithShiftReturnIsStillOneMessage() {
        let composer = ComposerWindow()
        defer { composer.close() }

        composer.offer("first")
        composer.pressReturn(shift: true)
        composer.pressReturn(shift: true)
        composer.pressReturn()

        XCTAssertEqual(composer.sent.count, 1, "the draft was submitted more than once")
        XCTAssertEqual(composer.sent.first, "first\n\n")
    }

    /// **Holding Shift+Enter must not submit either, and a `.down`-only handler let it.**
    ///
    /// macOS auto-repeats a held key past the repeat delay, and SwiftUI classifies those ticks
    /// as the `.repeat` phase. A handler subscribed to `.down` alone is not merely not called
    /// for them — the event falls through to AppKit exactly as an explicit `.ignored` would,
    /// reaches `insertNewline:`, and fires `.onSubmit`. So the *tap* was fixed and the *hold*
    /// was still #119, on a chord people hold rather than tap. Found by a reviewer on this
    /// diff and reproduced here before it was believed.
    func testHoldingShiftReturnDoesNotSubmitOnTheRepeat() {
        let composer = ComposerWindow()
        defer { composer.close() }

        composer.offer("hello")
        composer.pressReturn(shift: true)
        composer.pressReturn(shift: true, held: true)

        XCTAssertEqual(
            composer.sent, [],
            "the auto-repeat of a held Shift+Enter submitted the draft — #119 for anyone who "
                + "holds the chord instead of tapping it")

        composer.pressReturn()
        XCTAssertEqual(
            composer.sent, ["hello\n\n"], "the repeat tick started no line of its own")
    }

    /// **A control: it passes either way**, and it is the one that would catch the fix
    /// overshooting into `.repeat`. A held plain Enter still submits on its first tick — the
    /// draft is empty after that, so the rest of the repeats are no-ops rather than a burst of
    /// blank messages.
    func testHoldingPlainEnterStillSubmitsOnceAndNoMore() {
        let composer = ComposerWindow()
        defer { composer.close() }

        composer.offer("hello")
        composer.pressReturn()
        composer.pressReturn(held: true)
        composer.pressReturn(held: true)

        XCTAssertEqual(composer.sent, ["hello"], "a held Enter sent something other than once")
    }

    /// **The one step of the real app this window cannot contain.**
    ///
    /// `Keymap` installs a local `NSEvent` monitor that runs *before* any view's key
    /// handling and returns nil for anything it claims — consumed events never reach a
    /// responder at all. A window built by a test has no such monitor, so every assertion
    /// above is made one layer below the app's own first stop, and a `Shortcut` row that
    /// happened to match a Return would eat both keys with all three still green.
    ///
    /// Asked of the same pure `match` the monitor asks, with the terminal both holding and
    /// not holding focus, because the map's `Focus` rows answer differently for each.
    func testHelmsKeyMapClaimsNeitherReturnNorShiftReturn() {
        for terminalFocused in [true, false] {
            for modifiers in [NSEvent.ModifierFlags(), .shift] {
                XCTAssertNil(
                    Shortcut.match(
                        characters: "\r", keyCode: 36, modifiers: modifiers,
                        terminalFocused: terminalFocused),
                    "helm's key map consumes Return (shift: \(modifiers.contains(.shift)), "
                        + "terminal focused: \(terminalFocused)), so it never reaches the "
                        + "composer or the agent's own TUI")
            }
        }
    }
}

// MARK: - Harness

/// The real composer in a real window, with the messages it handed on.
@MainActor
private final class ComposerWindow {
    private let window: NSWindow
    private let box = Box()
    private let scratch: URL

    var sent: [String] { box.sent }

    init() {
        // A test bundle is not an app, and AppKit will not deliver a key event through a
        // window that belongs to no application. `.accessory` keeps it out of the Dock and
        // off the operator's screen — nothing here activates.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-composer-\(UUID().uuidString)")
        let registry = scratch.appendingPathComponent("sessions")
        try! FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        // The composer only submits while the agent is idle (`ChatComposerGateTests`), so an
        // idle agent is a precondition of asking what Return does at all.
        try! #"{"pid":4242,"sessionId":"s","cwd":"/tmp/ws","status":"idle"}"#.write(
            to: registry.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        let model = ChatModel(
            registryRoot: registry, transcriptRoot: scratch.appendingPathComponent("projects"))
        model.tick(foregroundPid: 4242)
        box.model = model

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Host(box: box, model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 120)
        window.contentView = hosting
        XCTAssertTrue(
            Eventually.holds { self.window.firstResponder is NSTextView },
            "the composer never took the keyboard, so no Return can reach it")
    }

    func close() {
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Put text in the draft the way a canvas `Post` does. The keyboard is already the
    /// composer's by then — `init` waits for that, because it is what makes the window worth
    /// sending a key to at all.
    ///
    /// The prefill route rather than typed letters on purpose: it is the composer's own
    /// supported way to be handed a draft, it focuses the field as a side effect the view
    /// already documents, and it keeps this suite's subject the **Return** rather than
    /// AppKit's key-to-character translation.
    func offer(_ text: String) {
        box.prefill = text
        // Consumption is the observable, and waiting on it is what makes the offer real:
        // `ChatComposer` clears `prefill` as it moves the text into its draft, so a nil here
        // is the composer saying it has the text — where a fixed pause would sometimes ask
        // before it did.
        XCTAssertTrue(
            Eventually.holds { self.box.prefill == nil },
            "the composer never took the offered text, so the draft is empty")
    }

    /// A key through the window, not into a view: `sendEvent` walks the responder chain, so
    /// this asks the question the operator asks.
    /// `held` is the auto-repeat tick macOS sends once a key is kept down past the repeat
    /// delay. SwiftUI classifies it as the `.repeat` phase rather than `.down`, and a handler
    /// that did not subscribe to it never sees the event at all.
    func pressReturn(
        shift: Bool = false, held: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // 36 is Return's ANSI virtual key code, so a synthesised event looks like a real
        // one. Unlike in `TerminalKeyboardTests`, where ghostty translates the *physical* key
        // and a wrong code produces a wrong byte, nothing here reads it: measured, all four
        // tests still pass with `keyCode: 0`, because AppKit and SwiftUI route this off
        // `characters`. Said so that the next reader does not inherit a borrowed reason.
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: held, keyCode: 36)
        guard let event else {
            return XCTFail("could not synthesise a Return key event", file: file, line: line)
        }
        window.sendEvent(event)
        // A *negative* claim follows every one of these — "nothing was sent" — and that has
        // no edge to wait for, so the hierarchy is given a chance to be wrong.
        Eventually.pump()
    }

    /// The composer's two mutable ends — what it is offered, and what it hands on.
    private final class Box: ObservableObject {
        @Published var prefill: String?
        /// Retained so the model outlives the initializer that built it; `ChatComposer` only
        /// observes it.
        var model: ChatModel?
        var sent: [String] = []
    }

    /// The binding the composer needs, owned by something the test can reach.
    private struct Host: View {
        @ObservedObject var box: Box
        @ObservedObject var model: ChatModel

        var body: some View {
            ChatComposer(
                model: model, send: { box.sent.append($0) }, prefill: $box.prefill,
                holdsKeyboard: true)
        }
    }
}
