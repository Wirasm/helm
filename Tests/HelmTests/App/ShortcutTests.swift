import AppKit
import XCTest

@testable import Helm

/// The keyboard map, which was previously a switch inside an `NSEvent` monitor and
/// therefore untestable — these are the rules that used to be verifiable only by
/// pressing keys on a running app.
final class ShortcutTests: XCTestCase {
    private func match(
        _ characters: String?, keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags,
        terminalFocused: Bool = false
    ) -> Shortcut? {
        Shortcut.match(
            characters: characters, keyCode: keyCode, modifiers: modifiers,
            terminalFocused: terminalFocused)
    }

    // MARK: - Focus rules (the reason the map cannot be a dictionary)

    func testPromptJumpFiresOnlyWhileTheTerminalHasFocus() {
        let focused = match(nil, keyCode: 126, .command, terminalFocused: true)
        XCTAssertEqual(focused?.notification, .helmJumpToPrompt)
        XCTAssertEqual(focused?.payload, -1)

        XCTAssertNil(
            match(nil, keyCode: 126, .command, terminalFocused: false),
            "⌘↑ must keep its text-navigation meaning outside the terminal")
    }

    func testControlDigitsAreNeverStolenFromAFocusedShell() {
        XCTAssertEqual(
            match("3", .control, terminalFocused: false)?.notification, .helmSelectWorkspace,
            "⌃3 switches workspace when the terminal does not have focus")
        XCTAssertNil(
            match("3", .control, terminalFocused: true),
            "a focused shell keeps legacy Ctrl+digit control codes")
    }

    func testWorkspaceCycleAlsoYieldsToAFocusedShell() {
        XCTAssertEqual(match(nil, keyCode: 123, .control)?.payload, -1)
        XCTAssertNil(match(nil, keyCode: 123, .control, terminalFocused: true))
    }

    func testCommandOptionDigitsWorkEvenWithTheTerminalFocused() {
        let shortcut = match("5", [.command, .option], terminalFocused: true)
        XCTAssertEqual(shortcut?.notification, .helmSelectWorkspace)
        XCTAssertEqual(
            shortcut?.payload, 4,
            "the ⌘⌥ fallback exists for operators who have not released Mission Control's ⌃1–⌃9")
    }

    // MARK: - Modifier sets must be exact

    func testCommandDigitSelectsATerminalAndIsNotConfusedWithWorkspaceBindings() {
        XCTAssertEqual(match("2", .command)?.notification, .helmSelectTerminal)
        XCTAssertEqual(match("2", .command)?.payload, 1, "keys are 1-based, indices 0-based")
    }

    func testShiftedOpenIsAWorkspaceAndBareOpenIsAnArtifact() {
        XCTAssertEqual(match("O", [.command, .shift])?.notification, .helmOpenWorkspace)
        XCTAssertEqual(match("o", .command)?.notification, .helmOpenArtifact)
    }

    func testLetterMatchingIsCaseInsensitiveSoAShiftedKeyStillResolves() {
        XCTAssertEqual(
            match("o", [.command, .shift])?.notification, .helmOpenWorkspace,
            "charactersIgnoringModifiers keeps shift applied, but the case must not decide")
        XCTAssertEqual(match("N", .command)?.notification, .helmNewTerminal)
    }

    /// ⌘T swaps the terminal pane between its two faces. It was reserved rather
    /// than free — the old two-faces toggle, freed by the one-surface re-layout —
    /// and the chat face claims it deliberately, being the same shape of command.
    ///
    /// `.anywhere`, because the terminal grid holds focus almost all the time and
    /// this has to work from there. The local monitor consumes it, so ghostty's
    /// own ⌘T (new tab) never sees it.
    func testCommandTSwapsTheTerminalPanesTwoFaces() {
        XCTAssertEqual(match("t", .command)?.notification, .helmToggleChat)
        XCTAssertEqual(
            match("t", .command, terminalFocused: true)?.notification, .helmToggleChat,
            "the terminal almost always has focus — a toggle it could not reach is no toggle")
    }

    // MARK: - Arranging the bench

    func testSplitBindings() {
        XCTAssertEqual(
            match("d", .command)?.notification, .helmSplitRight,
            "⌘D — a new column right of the focused one")
        XCTAssertEqual(
            match("D", [.command, .shift])?.notification, .helmSplitDown,
            "⌘⇧D — a new row under the focused slot; charactersIgnoringModifiers keeps shift "
                + "applied, so this arrives uppercase")
    }

    func testShiftCommandRTogglesTheArchonRail() {
        XCTAssertEqual(match("r", [.command, .shift])?.notification, .helmToggleRail)
    }

    /// ⌘W is unavailable — SwiftUI's `WindowGroup` binds it to close-window — so the pane
    /// close is ⌘⌥W.
    func testClosePaneAvoidsTheWindowClose() {
        XCTAssertEqual(match("w", [.command, .option])?.notification, .helmClosePane)
        XCTAssertNil(match("w", .command), "⌘W belongs to the window, and helm must not fight it")
    }

    /// ⌘⌥1–9 is already the workspace fallback, which is why focus movement is on arrows.
    /// The payload is a `Workbench.Direction` raw value rather than an index.
    func testFocusMovementCarriesADirection() {
        for (keyCode, direction) in [
            (UInt16(123), Workbench.Direction.left), (124, .right), (126, .up), (125, .down),
        ] {
            let shortcut = match(nil, keyCode: keyCode, [.command, .option])
            XCTAssertEqual(shortcut?.notification, .helmMoveFocus, "keyCode \(keyCode)")
            XCTAssertEqual(shortcut?.object as? String, direction.rawValue)
        }
    }

    /// `match` returns the FIRST row whose trigger and modifier set agree, so a duplicate
    /// triple would silently shadow whatever came after it.
    func testNoTwoRowsShareATriggerModifierAndFocusTriple() {
        var seen: Set<String> = []
        for shortcut in Shortcut.all {
            let triple = "\(shortcut.trigger)|\(shortcut.modifiers.rawValue)|\(shortcut.focus)"
            XCTAssertTrue(
                seen.insert(triple).inserted,
                "two rows claim \(triple); the second can never fire")
        }
    }

    func testUnboundCombinationsPassThrough() {
        XCTAssertNil(match("j", .command), "⌘J is deliberately unbound — reserved for maximize")
        XCTAssertNil(match("q", .command), "unclaimed keys must reach the system")
        XCTAssertNil(match("n", []), "a bare letter must reach the pty")
    }

    // MARK: - Font size

    func testBothWaysOfTypingPlusIncreaseTheFontSize() {
        for (characters, modifiers) in [
            ("=", NSEvent.ModifierFlags.command), ("+", .command), ("+", [.command, .shift]),
        ] {
            XCTAssertEqual(
                match(characters, modifiers)?.payload, FontSizeStep.increase.rawValue,
                "\(modifiers) + \(characters) must increase the font size")
        }
        XCTAssertEqual(match("-", .command)?.payload, FontSizeStep.decrease.rawValue)
        XCTAssertEqual(match("0", .command)?.payload, FontSizeStep.reset.rawValue)
    }

    // MARK: - Table integrity

    func testEveryMenuEntryResolvesFromItsOwnKeystroke() {
        // The point of building the menu from the table: a menu row cannot name a
        // shortcut the keyboard map does not actually bind.
        for shortcut in Shortcut.all where shortcut.menu != nil {
            switch shortcut.trigger {
            case let .character(character):
                XCTAssertNotNil(
                    match(character, shortcut.modifiers, terminalFocused: false),
                    "menu entry \(shortcut.menu!.title) does not resolve from its own keystroke")
            case let .keyCode(code):
                XCTAssertNotNil(
                    match(nil, keyCode: code, shortcut.modifiers, terminalFocused: true),
                    "menu entry \(shortcut.menu!.title) does not resolve from its own keystroke")
            }
        }
    }

    func testNoTwoRowsClaimTheSameKeystrokeUnderTheSameFocus() {
        for (index, shortcut) in Shortcut.all.enumerated() {
            let duplicate = Shortcut.all.enumerated().first { other, candidate in
                other != index && candidate.trigger == shortcut.trigger
                    && candidate.modifiers == shortcut.modifiers
                    && candidate.focus == shortcut.focus
            }
            XCTAssertNil(
                duplicate,
                "two rows claim the same trigger + modifiers + focus; the second is unreachable")
        }
    }
}
