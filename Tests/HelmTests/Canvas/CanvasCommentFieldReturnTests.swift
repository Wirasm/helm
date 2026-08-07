import AppKit
import SwiftUI
import XCTest

@testable import Helm

/// **What a Return in the canvas comment field does — asked of a real key event.**
///
/// The third instance of the shape #275 fixed in the chat composer: a
/// `TextField(axis: .vertical)` with `.onSubmit` and nothing beside it. AppKit's
/// `StandardKeyBinding.dict` maps `\r` to `insertNewline:` and `~\r` to
/// `insertNewlineIgnoringFieldEditor:` and **has no entry for Shift-Return at all**, so a
/// shifted Return is an ordinary one and the note was written half-finished. A note is prose
/// about a passage, which is exactly the kind of writing that runs past one line (#278).
///
/// The harness is `ChatComposerReturnTests`', on purpose — a real `NSWindow` around the real
/// `CanvasCommentField`, real `NSEvent`s through `NSWindow.sendEvent`. **No WebKit and no
/// ghostty surface**: the field is a field, and what it is drawn over does not decide what a
/// Return means.
@MainActor
final class CanvasCommentFieldReturnTests: XCTestCase {
    private var canvas: URL!

    override func setUpWithError() throws {
        canvas = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-canvas-\(UUID().uuidString).md")
        try "# plan".write(to: canvas, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: canvas)
        try? FileManager.default.removeItem(at: CanvasNotes.sidecarURL(for: canvas))
    }

    /// **A control: it passes either way.** It cannot fail unless the fix overshoots and takes
    /// plain Return with it — which is the one way this change could break the field outright,
    /// and the reason a test that only proves Shift+Return stopped writing would be satisfied by
    /// a field that never writes at all.
    func testReturnWritesTheNote() throws {
        let field = try CommentWindow(canvas: canvas)
        defer { field.close() }

        field.type("the loop reads backwards")
        field.pressReturn()

        XCTAssertTrue(
            field.wroteNotes(1),
            "Enter no longer writes the note (the field says: "
                + "\(field.model.notesFailure ?? "nothing"))")
        XCTAssertTrue(
            field.sidecar.contains("the loop reads backwards"),
            "the note that was written is not the one that was typed: \(field.sidecar)")
    }

    /// **Shift+Enter starts a new line and writes nothing.**
    ///
    /// Both halves matter. "Nothing was written" alone is satisfied by a Shift+Return that is
    /// swallowed whole, which would be a different bug wearing the same green — so the field's
    /// own text is asserted, and then the Return that follows proves the newline really reaches
    /// the sidecar rather than being dropped on the way.
    func testShiftReturnStartsALineAndWritesNothing() throws {
        let field = try CommentWindow(canvas: canvas)
        defer { field.close() }

        field.type("the loop reads backwards")
        field.pressReturn(shift: true)

        XCTAssertTrue(
            field.shows("the loop reads backwards\n"),
            "Shift+Enter did not start a line — the field shows \(field.shown.debugDescription)")
        XCTAssertEqual(
            field.model.notes, [],
            "Shift+Enter wrote the note, so the operator's second line never existed")
        XCTAssertNil(field.model.notesFailure, "and nothing was attempted")

        field.type("and the retry never fires")
        field.pressReturn()

        XCTAssertTrue(field.wroteNotes(1), "the finished note was never written")
        XCTAssertTrue(
            field.sidecar.contains("the loop reads backwards\nand the retry never fires"),
            "the note carries no newline, so Shift+Enter inserted nothing: \(field.sidecar)")
    }

    /// **Holding Shift+Enter must not write either, and a `.down`-only handler let it.**
    ///
    /// macOS auto-repeats a held key past the repeat delay, and SwiftUI classifies those ticks
    /// as the `.repeat` phase. A handler subscribed to `.down` alone is not merely not called
    /// for them — the event falls through to AppKit exactly as an explicit `.ignored` would,
    /// reaches `insertNewline:`, and fires `.onSubmit`. So the *tap* would be fixed and the
    /// *hold* would not, on a chord people hold rather than tap. A reviewer found it on #275 and
    /// it was reproduced before it was believed; #278 says in as many words that this case must
    /// be covered here.
    func testHoldingShiftReturnDoesNotWriteOnTheRepeat() throws {
        let field = try CommentWindow(canvas: canvas)
        defer { field.close() }

        field.type("the loop reads backwards")
        field.pressReturn(shift: true)
        field.pressReturn(shift: true, held: true)

        XCTAssertTrue(
            field.shows("the loop reads backwards\n\n"),
            "the auto-repeat tick of a held Shift+Enter started no line of its own — the field "
                + "shows \(field.shown.debugDescription)")
        XCTAssertEqual(
            field.model.notes, [],
            "the auto-repeat of a held Shift+Enter wrote the note — #278 for anyone who holds "
                + "the chord instead of tapping it")
    }

    /// **A control: it passes either way**, and it is the one that would catch the fix
    /// overshooting into `.repeat`. A held plain Enter still writes on its first tick — the
    /// comment is empty after that and the selection is gone, so the repeats that follow write
    /// nothing rather than becoming a burst of empty notes.
    func testHoldingPlainReturnStillWritesOnceAndNoMore() throws {
        let field = try CommentWindow(canvas: canvas)
        defer { field.close() }

        field.type("the loop reads backwards")
        field.pressReturn()
        XCTAssertTrue(field.wroteNotes(1), "Enter no longer writes at all")

        field.pressReturn(held: true)
        field.pressReturn(held: true)
        Eventually.pump()

        XCTAssertEqual(
            field.model.notes.count, 1, "a held Enter wrote something other than exactly once")
    }
}

// MARK: - Harness

/// The real comment field in a real window, over a real canvas file.
@MainActor
private final class CommentWindow {
    let model = CanvasModel()
    private let window: NSWindow

    init(canvas: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        // A test bundle is not an app, and AppKit will not deliver a key event through a window
        // that belongs to no application. `.accessory` keeps it out of the Dock and off the
        // operator's screen — nothing here activates.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        model.open(canvas)
        // The field is drawn *over a selection*, and `annotate` needs one to anchor to — without
        // it every Return would write nothing and the "Shift+Enter wrote nothing" assertions
        // would pass for that reason instead of the one they name.
        let payload: [String: Any] = ["id": "phase-2", "text": "Phase 2"]
        let selection = try XCTUnwrap(
            CanvasSelection(payload), "could not build a selection to comment on",
            file: file, line: line)
        model.pageDidReport(.selected(selection))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(
            rootView: CanvasCommentField(model: model, selection: selection))
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 160)
        window.contentView = hosting
        // The field focuses itself on appear, so unlike the Archon rail there is nothing to hand
        // the keyboard to by hand — what ends up first responder is the field editor SwiftUI's
        // text field opens.
        XCTAssertTrue(
            Eventually.holds { self.window.firstResponder is NSTextView },
            "the comment field never took the keyboard, so no Return can reach it",
            file: file, line: line)
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    /// What the operator can see in the field. The comment is `@State` inside the view and there
    /// is no route to it from out here, which is fine — what is on screen is the better subject
    /// anyway, and it is what the next keystroke will be appended to.
    var shown: String {
        (window.firstResponder as? NSTextView)?.string ?? ""
    }

    /// The sidecar as written, for asserting on what the note actually says.
    var sidecar: String {
        model.notesText ?? ""
    }

    func shows(_ text: String) -> Bool {
        Eventually.holds { self.shown == text }
    }

    func wroteNotes(_ count: Int) -> Bool {
        Eventually.holds { self.model.notes.count == count }
    }

    /// Type, through the window, the way the operator does.
    func type(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = shown + text
        for character in text {
            send(
                characters: String(character), modifiers: [], held: false, keyCode: 0,
                file: file, line: line)
        }
        XCTAssertTrue(
            Eventually.holds { self.shown == expected },
            "typing \(text.debugDescription) did not reach the field, which shows "
                + "\(shown.debugDescription)", file: file, line: line)
        // **And then a settle, which is the one place here a duration is honest.** A keystroke
        // lands in the field editor and SwiftUI pushing the binding's new value back into that
        // editor is the other direction, on its own schedule; the text matching is not the same
        // as that update having *finished*. A synthetic Return arriving inside that window —
        // which no hand could type — leaves the editor pushing its own older value afterwards,
        // and the newline is gone. Measured on `ArchonRailReturnTests`, where the draft went
        // `"first line\n"` and the next typed word made it `"first linesecond line"`.
        Eventually.pump()
    }

    /// A key through the window, not into a view: `sendEvent` walks the responder chain, so this
    /// asks the question the operator asks.
    ///
    /// `held` is the auto-repeat tick macOS sends once a key is kept down past the repeat delay.
    /// SwiftUI classifies it as the `.repeat` phase rather than `.down`, and a handler that did
    /// not subscribe to it never sees the event at all.
    func pressReturn(
        shift: Bool = false, held: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // 36 is Return's ANSI virtual key code, so a synthesised event looks like a real one.
        send(
            characters: "\r", modifiers: shift ? .shift : [], held: held, keyCode: 36,
            file: file, line: line)
        // A *negative* claim follows most of these — "nothing was written" — and that has no
        // edge to wait for, so the hierarchy is given a chance to be wrong.
        Eventually.pump()
    }

    private func send(
        characters: String, modifiers: NSEvent.ModifierFlags, held: Bool, keyCode: UInt16,
        file: StaticString, line: UInt
    ) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: held, keyCode: keyCode)
        guard let event else {
            return XCTFail(
                "could not synthesise a key event for \(characters.debugDescription)",
                file: file, line: line)
        }
        window.sendEvent(event)
    }
}
