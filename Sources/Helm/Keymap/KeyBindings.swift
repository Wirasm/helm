import AppKit
import HelmWire
import SwiftUI

/// Every key helm binds, as one table (`KeyBinding`).
///
/// **⌘T and ⌘J are unbound.** ⌘T left with the chat face (#375); ⌘J is reserved for terminal
/// maximize. Muscle memory lives here.
enum KeyBindings {
    /// In hint order: the status bar shows hints in the order their label first appears here,
    /// and the menu lists items in this order. Match order would only matter where two rows
    /// could both match, and `BindingTableTests` forbids that.
    ///
    /// Built from named groups because one literal this size is more than the type checker will
    /// take in reasonable time.
    static let all: [KeyBinding] =
        panes + tabs + focusSteps + paneMoves + turns + workspaceKeys + chrome + fontSize

    private static let panes: [KeyBinding] = [
        KeyBinding(
            .character("n"), .command, .verb(.newTerminal), hint: "new",
            menu: .init(title: "New Terminal", key: "n", modifiers: .command)),
        // ⌘⇧N — a note, beside ⌘N because it is the same shape one surface over: ⌘N makes a
        // pane to work in, ⌘⇧N one to write in. Shift arrives applied and `match` folds case,
        // so the modifier set is what separates the two rows.
        KeyBinding(
            .character("n"), [.command, .shift], .local(.newNote), hint: "note",
            menu: .init(title: "New Note", key: "n", modifiers: [.command, .shift])),
        KeyBinding(
            .character("d"), .command, .verb(.split(.right)), hint: "split",
            menu: .init(title: "Split Right", key: "d", modifiers: .command)),
        KeyBinding(
            .character("d"), [.command, .shift], .verb(.split(.down)), hint: "split down",
            menu: .init(title: "Split Down", key: "d", modifiers: [.command, .shift])),
        // ⌘⌥W, because ⌘W belongs to SwiftUI's `WindowGroup` (close window) and helm would be
        // fighting its own shell for it.
        KeyBinding(
            .character("w"), [.command, .option], .verb(.closeFocused), hint: "close",
            menu: .init(title: "Close Pane", key: "w", modifiers: [.command, .option])),
    ]

    /// ⌘1–⌘9: a tab of the focused slot, by position (1-based keys, 0-based index).
    private static let tabs: [KeyBinding] = (1...9).map { index in
        KeyBinding(
            .character("\(index)"), .command, .verb(.showTab(index: index - 1)), hint: "pane")
    }

    /// ⌘⌥ + arrows, because ⌘⌥1–9 is already the workspace fallback.
    private static let focusSteps: [KeyBinding] = arrows.map { keyCode, direction, key, name in
        KeyBinding(
            .keyCode(keyCode), [.command, .option], .verb(.stepFocus(direction)), hint: "focus",
            menu: .init(title: "Focus \(name)", key: key, modifiers: [.command, .option]))
    }

    /// ⌘⌥⇧ + arrows — the same four keys with shift, moving the **pane** rather than the
    /// keyboard (#287). Shift turns *go there* into *take this there*, and the two sit side by
    /// side on the status bar because reading them together is what teaches the second one.
    /// `.anywhere`, like focus: the terminal holds the keyboard almost all the time, so a key
    /// that could not fire from inside a pane could not move that pane.
    private static let paneMoves: [KeyBinding] = arrows.map { keyCode, direction, key, name in
        KeyBinding(
            .keyCode(keyCode), [.command, .option, .shift], .verb(.moveFocused(direction)),
            hint: "move",
            menu: .init(
                title: "Move Pane \(name)", key: key, modifiers: [.command, .option, .shift]))
    }

    /// ⌘O and ⌘↑/⌘↓. The prompt jumps fire only inside a terminal, so ⌘↑/⌘↓ keeps its
    /// text-navigation meaning everywhere else.
    private static let turns: [KeyBinding] = [
        KeyBinding(
            .character("o"), .command, .local(.openArtifactPanel), hint: "artifact",
            menu: .init(title: "Open Artifact…", key: "o", modifiers: .command)),
        KeyBinding(
            .keyCode(126), .command, .local(.jumpToPrompt(offset: -1)), when: .terminalFocused,
            hint: "turn",
            menu: .init(title: "Jump to Previous Prompt", key: .upArrow, modifiers: .command)),
        KeyBinding(
            .keyCode(125), .command, .local(.jumpToPrompt(offset: 1)), when: .terminalFocused,
            hint: "turn",
            menu: .init(title: "Jump to Next Prompt", key: .downArrow, modifiers: .command)),
    ]

    /// ⌃1–⌃9 and ⌃←/⌃→ are Mission Control's keys when the operator has handed them over, and
    /// are never stolen from a focused shell, which owns them as control codes. ⌘⌥1–⌘⌥9 is the
    /// fallback that needs no System Settings change and fires anywhere.
    private static let workspaceKeys: [KeyBinding] =
        (1...9).map { index in
            KeyBinding(
                .character("\(index)"), .control, .verb(.activateWorkspace(index: index - 1)),
                when: .awayFromTerminal, hint: "workspace")
        }
        + (1...9).map { index in
            KeyBinding(
                .character("\(index)"), [.command, .option],
                .verb(.activateWorkspace(index: index - 1)), hint: "workspace")
        }
        + [
            KeyBinding(
                .keyCode(123), .control, .verb(.cycleWorkspace(delta: -1)),
                when: .awayFromTerminal, hint: "cycle"),
            KeyBinding(
                .keyCode(124), .control, .verb(.cycleWorkspace(delta: 1)),
                when: .awayFromTerminal, hint: "cycle"),
        ]

    private static let chrome: [KeyBinding] = [
        KeyBinding(
            .character("o"), [.command, .shift], .local(.openWorkspacePanel), hint: "folder",
            menu: .init(title: "Open Workspace…", key: "o", modifiers: [.command, .shift])),
        KeyBinding(
            .character("r"), [.command, .shift], .local(.toggleRail), hint: "archon",
            menu: .init(title: "Toggle Archon Rail", key: "r", modifiers: [.command, .shift])),
        // ⌘⇧B — the shared browser (#350), offered: it appears and the keyboard stays put.
        KeyBinding(
            .character("b"), [.command, .shift], .verb(.openBrowser), hint: "browser",
            menu: .init(title: "Shared Browser", key: "b", modifiers: [.command, .shift])),
    ]

    /// No hint (`KeyHint`'s header says why), but every one keeps a menu item or a key.
    private static let fontSize: [KeyBinding] = [
        KeyBinding(
            .character("="), .command, .local(.adjustFontSize(.increase)),
            menu: .init(title: "Increase Font Size", key: "+", modifiers: .command)),
        // ⌘+ and ⌘⇧= are the other two ways ⌘+ is typed: `charactersIgnoringModifiers` keeps
        // shift applied.
        KeyBinding(.character("+"), .command, .local(.adjustFontSize(.increase))),
        KeyBinding(.character("+"), [.command, .shift], .local(.adjustFontSize(.increase))),
        KeyBinding(
            .character("-"), .command, .local(.adjustFontSize(.decrease)),
            menu: .init(title: "Decrease Font Size", key: "-", modifiers: .command)),
        KeyBinding(
            .character("0"), .command, .local(.adjustFontSize(.reset)),
            menu: .init(title: "Reset Font Size", key: "0", modifiers: .command)),
    ]

    /// The four arrows, shared by focus and move because they are the same geometry — two
    /// copies of this would be two places to get ← and → the wrong way round.
    private static let arrows: [(UInt16, BenchDirection, KeyEquivalent, String)] = [
        (123, .left, .leftArrow, "Left"),
        (124, .right, .rightArrow, "Right"),
        (126, .up, .upArrow, "Up"),
        (125, .down, .downArrow, "Down"),
    ]

    /// The row a keystroke fires, if any.
    ///
    /// Pure on purpose — `terminalFocused` is passed in rather than read from
    /// `TerminalManager.shared`, so the whole table is exercisable from `swift test` with no
    /// window, no ghostty runtime and no focus to simulate.
    static func match(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        terminalFocused: Bool, in table: [KeyBinding] = all
    ) -> KeyBinding? {
        table.first { row in
            guard row.modifiers == modifiers, row.canFire(terminalFocused: terminalFocused)
            else { return false }
            switch row.trigger {
            case let .keyCode(code): return code == keyCode
            case let .character(character):
                // Case-folded: a shifted letter arrives uppercase, and the modifier set is what
                // tells ⌘O from ⌘⇧O.
                return character.lowercased() == characters?.lowercased()
            }
        }
    }
}
