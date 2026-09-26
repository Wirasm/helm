import AppKit
import HelmWire
import SwiftUI
import XCTest

@testable import Helm

/// The key table (`KeyBindings.all`), which was once a switch inside an `NSEvent` monitor and
/// therefore untestable — these are the rules that used to be verifiable only by pressing keys
/// on a running app. It replaced `ShortcutTests` when the table replaced `Shortcut` (#354's
/// PR 3b), and every rule that file pinned is still pinned here, against the row's action.
final class BindingTableTests: XCTestCase {
    private func match(
        _ characters: String?, keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags,
        terminalFocused: Bool = false
    ) -> KeyBinding.Action? {
        KeyBindings.match(
            characters: characters, keyCode: keyCode, modifiers: modifiers,
            terminalFocused: terminalFocused, in: KeyBindings.all)?.action
    }

    // MARK: - Focus rules (the reason the map cannot be a dictionary)

    func testPromptJumpFiresOnlyWhileTheTerminalHasFocus() {
        let focused = match(nil, keyCode: 126, .command, terminalFocused: true)
        XCTAssertEqual(focused, .local(.jumpToPrompt(offset: -1)))

        XCTAssertNil(
            match(nil, keyCode: 126, .command, terminalFocused: false),
            "⌘↑ must keep its text-navigation meaning outside the terminal")
    }

    func testControlDigitsAreNeverStolenFromAFocusedShell() {
        XCTAssertEqual(
            match("3", .control, terminalFocused: false), .verb(.activateWorkspace(index: 2)),
            "⌃3 switches workspace when the terminal does not have focus")
        XCTAssertNil(
            match("3", .control, terminalFocused: true),
            "a focused shell keeps legacy Ctrl+digit control codes")
    }

    func testWorkspaceCycleAlsoYieldsToAFocusedShell() {
        XCTAssertEqual(match(nil, keyCode: 123, .control), .verb(.cycleWorkspace(delta: -1)))
        XCTAssertNil(match(nil, keyCode: 123, .control, terminalFocused: true))
    }

    func testCommandOptionDigitsWorkEvenWithTheTerminalFocused() {
        XCTAssertEqual(
            match("5", [.command, .option], terminalFocused: true),
            .verb(.activateWorkspace(index: 4)),
            "the ⌘⌥ fallback exists for operators who have not released Mission Control's ⌃1–⌃9")
    }

    // MARK: - Modifier sets must be exact

    func testCommandDigitSelectsATerminalAndIsNotConfusedWithWorkspaceBindings() {
        XCTAssertEqual(
            match("2", .command), .verb(.showTab(index: 1)),
            "keys are 1-based, indices 0-based")
    }

    func testShiftedOpenIsAWorkspaceAndBareOpenIsAnArtifact() {
        XCTAssertEqual(match("O", [.command, .shift]), .local(.openWorkspacePanel))
        XCTAssertEqual(match("o", .command), .local(.openArtifactPanel))
    }

    /// ⌘N makes a pane to work in and ⌘⇧N one to write in (#289) — the same
    /// shift-on-top-of-the-base-binding pairing moving a pane has with moving focus. The modifier set
    /// is compared exactly, which is the whole of what separates the two rows.
    func testShiftedNewIsANoteAndBareNewIsATerminal() {
        XCTAssertEqual(match("N", [.command, .shift]), .local(.newNote))
        XCTAssertEqual(match("n", .command), .verb(.newTerminal))
    }

    func testLetterMatchingIsCaseInsensitiveSoAShiftedKeyStillResolves() {
        XCTAssertEqual(
            match("o", [.command, .shift]), .local(.openWorkspacePanel),
            "charactersIgnoringModifiers keeps shift applied, but the case must not decide")
        XCTAssertEqual(match("N", .command), .verb(.newTerminal))
    }

    // MARK: - Arranging the bench

    func testSplitBindings() {
        XCTAssertEqual(
            match("d", .command), .verb(.split(.right)),
            "⌘D — a new column right of the focused one")
        XCTAssertEqual(
            match("D", [.command, .shift]), .verb(.split(.down)),
            "⌘⇧D — a new row under the focused slot; charactersIgnoringModifiers keeps shift "
                + "applied, so this arrives uppercase")
    }

    func testShiftCommandRTogglesTheArchonRail() {
        XCTAssertEqual(match("r", [.command, .shift]), .local(.toggleRail))
    }

    /// ⌘W is unavailable — SwiftUI's `WindowGroup` binds it to close-window — so the pane
    /// close is ⌘⌥W.
    func testClosePaneAvoidsTheWindowClose() {
        XCTAssertEqual(match("w", [.command, .option]), .verb(.closeFocused))
        XCTAssertNil(match("w", .command), "⌘W belongs to the window, and helm must not fight it")
    }

    /// ⌘⌥1–9 is already the workspace fallback, which is why focus movement is on arrows, and
    /// moving the pane is the same four arrows with shift (#287). The direction travels as
    /// itself — it once travelled as its raw value, and there is nothing left to flatten (#218).
    func testFocusAndMoveCarryADirection() {
        for (keyCode, direction) in [
            (UInt16(123), BenchDirection.left), (124, .right), (126, .up), (125, .down),
        ] {
            XCTAssertEqual(
                match(nil, keyCode: keyCode, [.command, .option]), .verb(.stepFocus(direction)),
                "keyCode \(keyCode)")
            XCTAssertEqual(
                match(nil, keyCode: keyCode, [.command, .option, .shift], terminalFocused: true),
                .verb(.moveFocused(direction)),
                "keyCode \(keyCode) — and from inside a terminal, which is where panes are moved")
        }
    }

    func testShiftCommandBOpensTheSharedBrowser() {
        XCTAssertEqual(match("B", [.command, .shift]), .verb(.openBrowser))
    }

    func testUnboundCombinationsPassThrough() {
        XCTAssertNil(match("j", .command), "⌘J is deliberately unbound — reserved for maximize")
        XCTAssertNil(match("t", .command), "⌘T left with the chat face (#375)")
        XCTAssertNil(match("q", .command), "unclaimed keys must reach the system")
        XCTAssertNil(match("n", []), "a bare letter must reach the pty")
    }

    // MARK: - Font size

    func testBothWaysOfTypingPlusIncreaseTheFontSize() {
        for (characters, modifiers) in [
            ("=", NSEvent.ModifierFlags.command), ("+", .command), ("+", [.command, .shift]),
        ] {
            XCTAssertEqual(
                match(characters, modifiers), .local(.adjustFontSize(.increase)),
                "\(modifiers) + \(characters) must increase the font size")
        }
        XCTAssertEqual(match("-", .command), .local(.adjustFontSize(.decrease)))
        XCTAssertEqual(match("0", .command), .local(.adjustFontSize(.reset)))
    }

    // MARK: - Table integrity

    /// The menu is built from the rows that have a `menu` (`KeyBindingMenu`), and an item fires
    /// its row's own action. This pins the other half: the item's row is also the row its own
    /// keystroke reaches, so a menu item cannot name a key that does something else.
    func testEveryMenuRowIsWhatItsOwnKeystrokeFires() {
        let menuRows = KeyBindings.all.filter { $0.menu != nil }
        XCTAssertFalse(menuRows.isEmpty)
        for row in menuRows {
            let characters: String? =
                if case let .character(character) = row.trigger { character } else { nil }
            let keyCode: UInt16 = if case let .keyCode(code) = row.trigger { code } else { 0 }
            XCTAssertEqual(
                match(
                    characters, keyCode: keyCode, row.modifiers,
                    terminalFocused: row.when == .terminalFocused),
                row.action,
                "menu item \(row.menu!) does not fire its own keystroke's action")
        }
    }

    /// A menu item prints its row's own chord, derived rather than spelled a second time, so
    /// the menu cannot name a key that the row does not bind.
    func testTheMenuPrintsEachRowsOwnChord() throws {
        func shortcut(_ title: String) throws -> KeyboardShortcut? {
            try XCTUnwrap(KeyBindings.all.first { $0.menu == title }, title).menuShortcut
        }
        XCTAssertEqual(
            try shortcut("Increase Font Size"), KeyboardShortcut("+", modifiers: .command))
        XCTAssertEqual(
            try shortcut("Focus Left"),
            KeyboardShortcut(.leftArrow, modifiers: [.command, .option]))
        XCTAssertEqual(
            try shortcut("Shared Browser"), KeyboardShortcut("b", modifiers: [.command, .shift]))
    }

    /// `match` returns the FIRST row that fits, so two rows that could both match one keystroke
    /// would leave the second unreachable. Two `When`s overlap unless they are the two opposite
    /// halves — `.anywhere` overlaps both.
    func testNoTwoRowsClaimOneChordInOverlappingWhens() {
        let rows = KeyBindings.all
        for (index, row) in rows.enumerated() {
            for other in rows[(index + 1)...] where other.collides(with: row) {
                XCTFail("two rows claim \(row.trigger) \(row.modifiers); the second is unreachable")
            }
        }
    }

    // MARK: - What a gesture resolves to

    private let first = UUID()
    private let second = UUID()
    private let workspaces = [WorkspacePath("/w/a"), WorkspacePath("/w/b"), WorkspacePath("/w/c")]

    /// Two tabs in one slot, the second selected and so holding the keyboard.
    private var bench: Workbench {
        Workbench(
            panes: [Pane(id: first, content: .terminal()), Pane(id: second, content: .terminal())],
            selecting: second)
    }

    private func resolve(_ template: VerbTemplate, active: Int? = 0) -> BenchVerb? {
        template.resolve(
            bench: bench, workspaces: workspaces, active: active.map { workspaces[$0] })
    }

    /// The table holds no ids: "the focused pane" and "the second tab" are read off the bench at
    /// the moment the key fires, and each gesture becomes exactly the verb it promises.
    func testEachGestureResolvesToTheVerbItPromises() {
        XCTAssertEqual(resolve(.newTerminal), .paneOpen(surface: .terminal(agent: nil)))
        XCTAssertEqual(resolve(.split(.down)), .paneSplit(direction: .down))
        XCTAssertEqual(resolve(.closeFocused), .paneClose(second))
        XCTAssertEqual(resolve(.showTab(index: 0)), .paneShow(first))
        XCTAssertEqual(resolve(.stepFocus(.left)), .focusStep(direction: .left))
        XCTAssertEqual(resolve(.moveFocused(.up)), .paneMove(second, .up))
        XCTAssertEqual(resolve(.openBrowser), .paneOpen(surface: .browser))
        XCTAssertEqual(resolve(.activateWorkspace(index: 2)), .workspaceActivate(path: "/w/c"))
    }

    func testCyclingWrapsBothWays() {
        XCTAssertEqual(
            resolve(.cycleWorkspace(delta: -1), active: 0), .workspaceActivate(path: "/w/c"))
        XCTAssertEqual(
            resolve(.cycleWorkspace(delta: 1), active: 2), .workspaceActivate(path: "/w/a"))
        XCTAssertEqual(
            resolve(.cycleWorkspace(delta: 1), active: nil), .workspaceActivate(path: "/w/b"),
            "with nothing active the cycle starts from the first")
    }

    /// A key that means nothing right now sends nothing — rather than a verb about a pane or a
    /// workspace that is not there.
    func testAGestureWithNothingToActOnResolvesToNoVerb() {
        XCTAssertNil(resolve(.showTab(index: 5)))
        XCTAssertNil(resolve(.activateWorkspace(index: 3)))
        XCTAssertNil(
            VerbTemplate.closeFocused.resolve(bench: nil, workspaces: [], active: nil))
        XCTAssertNil(
            VerbTemplate.cycleWorkspace(delta: 1).resolve(bench: nil, workspaces: [], active: nil))
    }
}
