import AppKit
import HelmWire
import SwiftUI

/// Every key helm binds by default, as one table (`KeyBinding`).
///
/// **The built-in defaults, and a Swift literal on purpose.** The operator's
/// `<bench root>/rules/keymap.toml` overlays this table (`Keymap`), and `docs/keymap.default.toml`
/// is its rendering, pinned by `KeymapFileTests`. A bundled default file would add the one
/// failure this must not have: a packaging mistake leaving helm with no keys at all.
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
            menu: "New Terminal"),
        // ⌘⇧N — a note, beside ⌘N because it is the same shape one surface over: ⌘N makes a
        // pane to work in, ⌘⇧N one to write in. Shift arrives applied and `match` folds case,
        // so the modifier set is what separates the two rows.
        KeyBinding(
            .character("n"), [.command, .shift], .local(.newNote), hint: "note",
            menu: "New Note"),
        KeyBinding(
            .character("d"), .command, .verb(.split(.right)), hint: "split",
            menu: "Split Right"),
        KeyBinding(
            .character("d"), [.command, .shift], .verb(.split(.down)), hint: "split down",
            menu: "Split Down"),
        // ⌘⌥W, because ⌘W belongs to SwiftUI's `WindowGroup` (close window) and helm would be
        // fighting its own shell for it.
        KeyBinding(
            .character("w"), [.command, .option], .verb(.closeFocused), hint: "close",
            menu: "Close Pane"),
    ]

    /// ⌘1–⌘9: a tab of the focused slot, by position (1-based keys, 0-based index).
    private static let tabs: [KeyBinding] = (1...9).map { index in
        KeyBinding(
            .character("\(index)"), .command, .verb(.showTab(index: index - 1)), hint: "pane")
    }

    /// ⌘⌥ + arrows, because ⌘⌥1–9 is already the workspace fallback.
    private static let focusSteps: [KeyBinding] = ArrowKey.allCases.map { arrow in
        KeyBinding(
            arrow.trigger, [.command, .option], .verb(.stepFocus(arrow.direction)), hint: "focus",
            menu: "Focus \(arrow.name.capitalized)")
    }

    /// ⌘⌥⇧ + arrows — the same four keys with shift, moving the **pane** rather than the
    /// keyboard (#287). Shift turns *go there* into *take this there*, and the two sit side by
    /// side on the status bar because reading them together is what teaches the second one.
    /// `.anywhere`, like focus: the terminal holds the keyboard almost all the time, so a key
    /// that could not fire from inside a pane could not move that pane.
    private static let paneMoves: [KeyBinding] = ArrowKey.allCases.map { arrow in
        KeyBinding(
            arrow.trigger, [.command, .option, .shift], .verb(.moveFocused(arrow.direction)),
            hint: "move",
            menu: "Move Pane \(arrow.name.capitalized)")
    }

    /// ⌘O and ⌘↑/⌘↓. The prompt jumps fire only inside a terminal, so ⌘↑/⌘↓ keeps its
    /// text-navigation meaning everywhere else.
    private static let turns: [KeyBinding] = [
        KeyBinding(
            .character("o"), .command, .local(.openArtifactPanel), hint: "artifact",
            menu: "Open Artifact…"),
        KeyBinding(
            ArrowKey.up.trigger, .command, .local(.jumpToPrompt(offset: -1)),
            when: .terminalFocused,
            hint: "turn",
            menu: "Jump to Previous Prompt"),
        KeyBinding(
            ArrowKey.down.trigger, .command, .local(.jumpToPrompt(offset: 1)),
            when: .terminalFocused,
            hint: "turn",
            menu: "Jump to Next Prompt"),
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
                ArrowKey.left.trigger, .control, .verb(.cycleWorkspace(delta: -1)),
                when: .awayFromTerminal, hint: "cycle"),
            KeyBinding(
                ArrowKey.right.trigger, .control, .verb(.cycleWorkspace(delta: 1)),
                when: .awayFromTerminal, hint: "cycle"),
        ]

    private static let chrome: [KeyBinding] = [
        KeyBinding(
            .character("o"), [.command, .shift], .local(.openWorkspacePanel), hint: "folder",
            menu: "Open Workspace…"),
        KeyBinding(
            .character("r"), [.command, .shift], .local(.toggleRail), hint: "archon",
            menu: "Toggle Archon Rail"),
        // ⌘⇧B — the shared browser (#350) in its drawer (#356): shown over the bench and hidden
        // again, and the bench under it never narrows. An empty drawer starts with the browser.
        KeyBinding(
            .character("b"), [.command, .shift],
            .verb(.toggleDrawer(name: "browser", surface: .browser)), hint: "browser",
            menu: "Shared Browser"),
        // ⌘⇧S — every agent session in the workspace, in a drawer on the left (#384).
        KeyBinding(
            .character("s"), [.command, .shift],
            .verb(.toggleDrawer(name: "sessions", surface: .sessions)), hint: "sessions",
            menu: "Sessions"),
    ]

    /// No hint (`KeyHint`'s header says why), but every one keeps a menu item or a key.
    private static let fontSize: [KeyBinding] = [
        KeyBinding(.character("="), .command, .local(.adjustFontSize(.increase))),
        // ⌘+ and ⌘⇧= are the other two ways ⌘+ is typed: `charactersIgnoringModifiers` keeps
        // shift applied. The menu item sits on ⌘+ because a menu prints the row's own chord,
        // and ⌘+ is how every macOS app names this one.
        KeyBinding(
            .character("+"), .command, .local(.adjustFontSize(.increase)),
            menu: "Increase Font Size"),
        KeyBinding(.character("+"), [.command, .shift], .local(.adjustFontSize(.increase))),
        KeyBinding(
            .character("-"), .command, .local(.adjustFontSize(.decrease)),
            menu: "Decrease Font Size"),
        KeyBinding(
            .character("0"), .command, .local(.adjustFontSize(.reset)),
            menu: "Reset Font Size"),
    ]

    /// The row a keystroke fires, if any.
    ///
    /// Pure on purpose — `terminalFocused` is passed in rather than read from
    /// `TerminalManager.shared`, so the whole table is exercisable from `swift test` with no
    /// window, no ghostty runtime and no focus to simulate.
    static func match(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        terminalFocused: Bool, in table: [KeyBinding]
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
