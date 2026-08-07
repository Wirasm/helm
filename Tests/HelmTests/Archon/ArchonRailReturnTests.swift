import AppKit
import SwiftUI
import XCTest

@testable import Helm

/// **What a Return in the Archon rail does — asked of a real key event, not of a function.**
///
/// The rail's field is the same `TextField(axis: .vertical)` + `.onSubmit` shape the chat
/// composer had before #275, and it had the same defect for the same reason: AppKit's
/// `StandardKeyBinding.dict` maps `\r` to `insertNewline:` and `~\r` to
/// `insertNewlineIgnoringFieldEditor:` and **has no entry for Shift-Return at all**, so a
/// shifted Return is an ordinary one and `.onSubmit` fires. That distinction cannot be made by
/// any function this suite could call directly — it is AppKit that decides what a Return means
/// — so these build a real `NSWindow` around the real `ArchonRailView` and push real `NSEvent`s
/// through `NSWindow.sendEvent`. The harness is `ChatComposerReturnTests`', on purpose.
///
/// **It matters more here than it did there.** In the composer a stray submit sends a message;
/// here `submit()` launches an Archon workflow — real work, on a real branch, that somebody has
/// to notice and unwind (#278). So the assertions are about what reached the Archon client, not
/// about a flag.
///
/// **No ghostty surface is involved**, which is deliberate: a rail needs a text field and a
/// window, not a terminal, so this suite keeps working on a machine where every display is
/// asleep and `ghostty_surface_new` refuses (#253).
@MainActor
final class ArchonRailReturnTests: XCTestCase {
    /// **A control: it passes either way.** It cannot fail unless the fix overshoots and takes
    /// plain Return with it — which is the one way this change could break the rail outright,
    /// and the reason a test that only proves Shift+Return stopped launching would be satisfied
    /// by a rail that never launches at all.
    func testReturnLaunchesTheWorkflow() async throws {
        let rail = try RailWindow(defaults: isolatedDefaults("archon-rail-return"))
        defer { rail.close() }

        rail.type("review the plan")
        rail.pressReturn()

        let launches = await rail.launches(reaching: 1)
        XCTAssertEqual(
            launches.map(\.input), ["review the plan"],
            "Enter no longer launches (rail says: \(rail.model.launchFailure ?? "nothing"))")
    }

    /// **Shift+Enter starts a new line and launches nothing.**
    ///
    /// Both halves matter. "Nothing was launched" alone is satisfied by a Shift+Return that is
    /// swallowed whole, which would be a different bug wearing the same green — so the draft is
    /// asserted too, and the Return that follows proves the newline really travels into the work
    /// Archon is asked to do rather than being dropped on the way.
    func testShiftReturnStartsALineAndLaunchesNothing() async throws {
        let rail = try RailWindow(defaults: isolatedDefaults("archon-rail-shift"))
        defer { rail.close() }

        rail.type("first line")
        rail.pressReturn(shift: true)

        let started = rail.drafts("first line\n")
        XCTAssertTrue(
            started,
            "Shift+Enter did not start a line in the rail's field — the draft is "
                + "\(rail.model.draft.debugDescription)")
        var launches = await rail.launchesAfterSettling()
        XCTAssertEqual(
            launches, [],
            "Shift+Enter launched an Archon workflow — real work on a real branch, from a "
                + "keystroke the operator meant as a newline")

        rail.type("second line")
        rail.pressReturn()

        launches = await rail.launches(reaching: 1)
        XCTAssertEqual(
            launches.map(\.input), ["first line\nsecond line"],
            "the instruction Archon was finally given carries no newline, so Shift+Enter "
                + "inserted nothing")
    }

    /// **Holding Shift+Enter must not launch either, and a `.down`-only handler let it.**
    ///
    /// macOS auto-repeats a held key past the repeat delay, and SwiftUI classifies those ticks
    /// as the `.repeat` phase. A handler subscribed to `.down` alone is not merely not called
    /// for them — the event falls through to AppKit exactly as an explicit `.ignored` would,
    /// reaches `insertNewline:`, and fires `.onSubmit`. So the *tap* would be fixed and the
    /// *hold* would still launch a workflow, on a chord people hold rather than tap. A reviewer
    /// found it on #275 and it was reproduced before it was believed; #278 says in as many words
    /// that this case must be covered here.
    func testHoldingShiftReturnDoesNotLaunchOnTheRepeat() async throws {
        let rail = try RailWindow(defaults: isolatedDefaults("archon-rail-held-shift"))
        defer { rail.close() }

        rail.type("first line")
        rail.pressReturn(shift: true)
        rail.pressReturn(shift: true, held: true)

        let bothStarted = rail.drafts("first line\n\n")
        XCTAssertTrue(
            bothStarted,
            "the auto-repeat tick of a held Shift+Enter started no line of its own — the draft "
                + "is \(rail.model.draft.debugDescription)")
        let launches = await rail.launchesAfterSettling()
        XCTAssertEqual(
            launches, [],
            "the auto-repeat of a held Shift+Enter launched an Archon workflow — #278 for "
                + "anyone who holds the chord instead of tapping it")
    }

    /// **A control: it passes either way**, and it is the one that would catch the fix
    /// overshooting into `.repeat`. A held plain Enter still launches on its first tick — the
    /// draft is empty after that, so the repeats that follow are refused by
    /// `ArchonRailModel.launch` rather than becoming a burst of empty workflows.
    func testHoldingPlainReturnStillLaunchesOnceAndNoMore() async throws {
        let rail = try RailWindow(defaults: isolatedDefaults("archon-rail-held-plain"))
        defer { rail.close() }

        rail.type("review the plan")
        rail.pressReturn()
        let first = await rail.launches(reaching: 1)
        XCTAssertEqual(first.count, 1, "Enter no longer launches at all")

        rail.pressReturn(held: true)
        rail.pressReturn(held: true)

        let launches = await rail.launchesAfterSettling()
        XCTAssertEqual(
            launches.map(\.input), ["review the plan"],
            "a held Enter launched something other than exactly once")
    }
}

// MARK: - Harness

/// The real rail in a real window, with the Archon client it launches through.
@MainActor
private final class RailWindow {
    let model: ArchonRailModel
    let client = FakeArchonClient()
    private let window: NSWindow
    private let field: NSTextField

    init(defaults: UserDefaults, file: StaticString = #filePath, line: UInt = #line) throws {
        // A test bundle is not an app, and AppKit will not deliver a key event through a window
        // that belongs to no application. `.accessory` keeps it out of the Dock and off the
        // operator's screen — nothing here activates.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        model = ArchonRailModel(
            client: client, worktreeClient: FakeWorktreeClient(), defaults: defaults)
        // **A workflow has to be chosen or nothing below measures anything.** `launch` refuses
        // an unconfigured rail before it ever reaches the client — "Choose a workflow in the
        // settings before launching." — and every "nothing was launched" assertion here would
        // then pass for that reason instead of the one it names.
        model.config = ArchonLaunchConfig(workflow: "review", worktree: .automatic)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(
            rootView: ArchonRailView(model: model, workspacePath: WorkspacePath("/tmp/project")))
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        window.contentView = hosting

        // **The rail does not focus its own field, unlike the chat composer.** Nothing in
        // `ArchonRailView` sets `composerFocused`, so in a window nobody has clicked in there is
        // no first responder for a Return to reach. The operator gets there by clicking; a test
        // hands the keyboard over directly instead, and asserts it arrived rather than assuming.
        //
        // That route is not a shortcut around the thing under test, and it was checked rather
        // than assumed: the same `makeFirstResponder` on the **chat composer** — a field this
        // repo already knows submits on Return — still submits, so a Return that does nothing
        // here would be the rail's answer and not the harness's.
        //
        // What ends up first responder is the **field editor** SwiftUI's `AppKitTextField`
        // opens, an `NSTextView` AppKit only builds once the field is being edited — which is
        // why there is nothing of that class to look for beforehand.
        var found: NSTextField?
        _ = Eventually.holds {
            found = Self.textField(in: hosting); return found != nil
        }
        field = try XCTUnwrap(
            found, "the rail never rendered an editable text field, so no Return can reach it",
            file: file, line: line)
        window.makeFirstResponder(field)
        XCTAssertTrue(
            Eventually.holds { self.window.firstResponder is NSTextView },
            "the rail's field never took the keyboard, so no Return can reach it",
            file: file, line: line)
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    /// Type, through the window, the way the operator does. The rail has no `prefill` route the
    /// way the composer does, and writing `model.draft` directly would be asking the model a
    /// question about itself — the subject here is what the **field** does with a key.
    func type(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = model.draft + text
        for character in text {
            send(
                characters: String(character), modifiers: [], held: false, keyCode: 0,
                file: file, line: line)
        }
        XCTAssertTrue(
            Eventually.holds { self.model.draft == expected },
            "typing \(text.debugDescription) did not reach the rail's draft, which is "
                + "\(model.draft.debugDescription)", file: file, line: line)
        // **And then wait for the field itself, not just the model.** A keystroke lands in the
        // *field editor*; the binding it drives is one direction and SwiftUI pushing the new
        // value back into that editor is the other, on its own schedule. A synthetic Return
        // arriving in between — which a human's fingers never manage — appends its newline to
        // the model while the editor still holds the older string, and the editor's next commit
        // wins. Measured on this suite: `"first line\n"` in the draft, and the next typed word
        // made it `"first linesecond line"`, with the field never catching up in 15 seconds.
        // A settled field is a precondition of asking what the *next* key does.
        XCTAssertTrue(
            Eventually.holds { self.editorText == self.model.draft },
            "the rail's field never caught up with its draft — showing "
                + "\(editorText.debugDescription) for \(model.draft.debugDescription)",
            file: file, line: line)
        // And then a settle on top, which is the one place here a duration is honest: the two
        // strings matching is not the same as SwiftUI having *finished* the update that made
        // them match, and a Return landing inside that window is one no hand could type. It
        // leaves the field pushing its own older value afterwards and the newline is gone.
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
    }

    /// What the operator can see in the field: the active field editor's text, or the field's
    /// own value before one is open.
    private var editorText: String {
        (window.firstResponder as? NSTextView)?.string ?? field.stringValue
    }

    /// Whether the field's binding reaches `text`. The `.onKeyPress` handler writes straight
    /// through it, so this is the newline arriving.
    func drafts(_ text: String) -> Bool {
        Eventually.holds { self.model.draft == text && self.editorText == text }
    }

    /// Everything Archon has been asked to run, once at least `count` requests have arrived.
    func launches(reaching count: Int) async -> [ArchonLaunchRequest] {
        _ = await settle { await self.client.launchRequests.count >= count }
        return await client.launchRequests
    }

    /// Everything Archon has been asked to run, after giving a launch every chance to happen.
    ///
    /// For the *negative* claims — "Shift+Enter launched nothing" — which have no edge to wait
    /// for by definition, so the rail is given a fixed grace to be wrong in instead.
    func launchesAfterSettling() async -> [ArchonLaunchRequest] {
        _ = await settle(within: 0.4) { false }
        return await client.launchRequests
    }

    /// **Waiting that yields as well as pumps, because the rail's submit is asynchronous.**
    ///
    /// `Eventually.holds` spins the runloop, and that is enough for everything AppKit and
    /// SwiftUI do here — a keystroke reaching a binding, a field editor opening. It is *not*
    /// enough for `ArchonRailView.submit`, which is `Task { await model.launch(…) }`: measured
    /// on the first run of this suite, the task starts (`isLaunching` goes true) and then never
    /// resumes across a full second of `RunLoop.run`, because resuming it means hopping onto the
    /// Archon client's actor and back. An `await` is what hands the cooperative runtime the
    /// thread. Both are needed, so this does both.
    private func settle(
        within ceiling: TimeInterval = Eventually.ceiling, _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(ceiling)
        while Date() < deadline {
            if await condition() { return true }
            await Task.yield()
            // `RunLoop.current` is unavailable from an async context; `Eventually.pump` is the
            // synchronous door to the same spin, and calling it from here is allowed.
            Eventually.pump(0.005)
        }
        return await condition()
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

    /// The field SwiftUI built for the rail's `TextField`, wherever it put it. **Editable**, so
    /// that the label AppKit nests inside it — and the rail's other static text — cannot stand
    /// in for it.
    private static func textField(in view: NSView) -> NSTextField? {
        if let text = view as? NSTextField, text.isEditable { return text }
        for child in view.subviews {
            if let found = textField(in: child) { return found }
        }
        return nil
    }
}
