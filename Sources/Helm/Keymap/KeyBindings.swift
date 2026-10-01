import AppKit
import HelmWire
import SwiftUI

/// Every key helm binds by default, as one table (`KeyBinding`).
///
/// **The built-in defaults, and a Swift literal on purpose.** The operator's
/// `~/.helm/bench/keymap.toml` overlays this table (`Keymap`), and `docs/keymap.default.toml`
/// is its rendering, pinned by `KeymapFileTests`. A bundled default file would add the one
/// failure this must not have: a packaging mistake leaving helm with no keys at all.
///
/// **⌘T, ⌘W, ⌘L, ⌘R, ⌘[ and ⌘] are the browser's, and only in a browser pane** (#542). Outside
/// one, ⌘T stays unbound (it left with the chat face, #375) and ⌘W stays the window's.
///
/// **⌘K, ⌘N, ⌘D and ⌘O are the page's in a browser pane** (#548): GitHub, Linear and Slack all
/// use ⌘K, and helm has no browser-pane use for any of the four. ⌘⇧P opens the palette from
/// there. What stays helm's in a browser pane does something to the bench or helm itself, which
/// is as useful from a page as from anywhere: ⌘J (zoom the slot), the ⌘⇧ drawers and toggles (⌘⇧B
/// is how the browser drawer closes), and ⌃1–9 and ⌃←/→ (workspaces). The page surface keeps
/// the menu's mirror of a page key from firing too (`bindsElsewhere`), which also gives ⌘↑/⌘↓
/// back to pages; the prompt-jump menu items used to take them.
enum KeyBindings {
    /// In hint order: the key pop-up shows hints in the order their label first appears here,
    /// and the menu lists items in this order. Match order would only matter where two rows
    /// could both match, and `BindingTableTests` forbids that.
    ///
    /// Built from named groups because one literal this size is more than the type checker will
    /// take in reasonable time.
    static let all: [KeyBinding] =
        panes + tabs + browser + focusSteps + paneMoves + turns + workspaceKeys + chrome
        + fontSize + pageZoom

    /// The manage key's modifiers (`ManageKey`, #498): every row on these, alone or with ⇧, is
    /// the manage layer, and moves with `manage = "…"` in the keymap file.
    private static let manage = ManageKey.builtIn.modifiers

    private static let panes: [KeyBinding] = [
        KeyBinding(
            .character("n"), .command, .verb(.newTerminal), when: .awayFromBrowser, hint: "new",
            menu: "New Terminal"),
        // ⌘⇧N — a note, beside ⌘N because it is the same shape one surface over: ⌘N makes a
        // pane to work in, ⌘⇧N one to write in. Shift arrives applied and `match` folds case,
        // so the modifier set is what separates the two rows.
        KeyBinding(
            .character("n"), [.command, .shift], .local(.newNote), hint: "note",
            menu: "New Note"),
        KeyBinding(
            .character("d"), .command, .verb(.split(.right)), when: .awayFromBrowser,
            hint: "split", menu: "Split Right"),
        KeyBinding(
            .character("d"), [.command, .shift], .verb(.split(.down)), hint: "split down",
            menu: "Split Down"),
        // Manage + W, because ⌘W belongs to SwiftUI's `WindowGroup` (close window) and helm
        // would be fighting its own shell for it.
        KeyBinding(
            .character("w"), manage, .verb(.closeFocused), hint: "close",
            menu: "Close Pane"),
    ]

    /// ⌘1–⌘9: a tab of the focused slot, by position (1-based keys, 0-based index). In a
    /// browser pane the same keys pick the browser's tab instead, as in any browser.
    private static let tabs: [KeyBinding] = (1...9).map { index in
        KeyBinding(
            .character("\(index)"), .command, .verb(.showTab(index: index - 1)),
            when: .awayFromBrowser, hint: "pane")
    }

    /// Chrome's own keys, while a browser pane holds the keyboard (#542). The monitor runs
    /// before the menu, so ⌘W here closes the tab rather than helm's window. No menu items: a
    /// menu item fires wherever the keyboard is, and outside the pane there is no tab to act on.
    private static let browser: [KeyBinding] =
        [
            KeyBinding(
                .character("t"), .command, .local(.browser(.newTab)), when: .browserFocused,
                hint: "new tab"),
            KeyBinding(
                .character("w"), .command, .local(.browser(.closeTab)), when: .browserFocused,
                hint: "close tab"),
            KeyBinding(
                .character("l"), .command, .local(.browser(.focusAddress)),
                when: .browserFocused, hint: "address"),
            KeyBinding(
                .character("r"), .command, .local(.browser(.reload)), when: .browserFocused,
                hint: "reload"),
            KeyBinding(
                .character("["), .command, .local(.browser(.back)), when: .browserFocused,
                hint: "back · forward"),
            KeyBinding(
                .character("]"), .command, .local(.browser(.forward)), when: .browserFocused,
                hint: "back · forward"),
        ]
        + (1...9).map { index in
            KeyBinding(
                .character("\(index)"), .command, .local(.browser(.showTab(index: index - 1))),
                when: .browserFocused, hint: "tab")
        }

    /// Vim's four letters, in vim's order, so the manage layer's focus and move keys sit on the
    /// home row as well as on the arrows (#498).
    private static let homeRow: [(String, ArrowKey)] = [
        ("h", .left), ("j", .down), ("k", .up), ("l", .right),
    ]

    /// Manage + arrows or H/J/K/L. The arrows carry the menu items; the letters are the same
    /// verbs a hand already on the home row can reach.
    private static let focusSteps: [KeyBinding] =
        ArrowKey.allCases.map { arrow in
            KeyBinding(
                arrow.trigger, manage, .verb(.stepFocus(arrow.direction)), hint: "focus",
                menu: "Focus \(arrow.name.capitalized)")
        }
        + homeRow.map { letter, arrow in
            KeyBinding(
                .character(letter), manage, .verb(.stepFocus(arrow.direction)), hint: "focus")
        }

    /// Manage + ⇧ + the same keys, moving the **pane** rather than the keyboard (#287). Shift
    /// turns *go there* into *take this there*, and the two sit side by side in the key pop-up
    /// because reading them together is what teaches the second one. `.anywhere`, like focus:
    /// the terminal holds the keyboard almost all the time, so a key that could not fire from
    /// inside a pane could not move that pane.
    private static let paneMoves: [KeyBinding] =
        ArrowKey.allCases.map { arrow in
            KeyBinding(
                arrow.trigger, manage.union(.shift), .verb(.moveFocused(arrow.direction)),
                hint: "move",
                menu: "Move Pane \(arrow.name.capitalized)")
        }
        + homeRow.map { letter, arrow in
            KeyBinding(
                .character(letter), manage.union(.shift), .verb(.moveFocused(arrow.direction)),
                hint: "move")
        }

    /// ⌘O and ⌘↑/⌘↓. The prompt jumps fire only inside a terminal, so ⌘↑/⌘↓ keeps its
    /// text-navigation meaning everywhere else.
    private static let turns: [KeyBinding] = [
        KeyBinding(
            .character("o"), .command, .local(.openArtifactPanel), when: .awayFromBrowser,
            hint: "artifact", menu: "Open Artifact…"),
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
    /// are never stolen from a focused shell, which owns them as control codes. Manage + 1–9 is
    /// the one that needs no System Settings change and fires anywhere.
    private static let workspaceKeys: [KeyBinding] =
        (1...9).map { index in
            KeyBinding(
                .character("\(index)"), .control, .verb(.activateWorkspace(index: index - 1)),
                when: .awayFromTerminal, hint: "workspace")
        }
        + (1...9).map { index in
            KeyBinding(
                .character("\(index)"), manage,
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
        // ⌘K — the command palette (#500): anything a key can do, found by typing its name.
        // A page's own ⌘K in a browser pane (#548), where ⌘⇧P is the way in, as in VS Code;
        // ⌘⇧P works everywhere, so one key opens the palette wherever the keyboard is.
        KeyBinding(
            .character("k"), .command, .local(.toggleCommandPalette), when: .awayFromBrowser,
            hint: "commands", menu: "Command Palette"),
        KeyBinding(
            .character("p"), [.command, .shift], .local(.toggleCommandPalette),
            hint: "commands"),
        KeyBinding(
            .character("o"), [.command, .shift], .local(.openWorkspacePanel), hint: "folder",
            menu: "Open Workspace…"),
        // ⌘⇧R — Archon's runs, gates and stage dots in a drawer along the bottom (#382).
        KeyBinding(
            .character("r"), [.command, .shift],
            .verb(.toggleDrawer(name: "archon", surface: .archon)), hint: "archon",
            menu: "Archon"),
        // ⌘⇧G — every git worktree on the machine, grouped by repository, on the right (#382).
        KeyBinding(
            .character("g"), [.command, .shift],
            .verb(.toggleDrawer(name: "worktrees", surface: .worktrees)), hint: "worktrees",
            menu: "Worktrees"),
        // ⌘J — the camera on the focused slot (`BenchCamera`): the bench laid out larger and
        // panned to it, the neighbours peeking in at the edges. ⌘J again returns. `.anywhere`,
        // because the pane you want to look at is usually the terminal holding the keyboard.
        KeyBinding(
            .character("j"), .command, .local(.toggleZoom), hint: "zoom", menu: "Zoom Pane"),
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
        // ⌘⇧A — keep the Mac and its displays awake while agents work (#496). The status bar
        // says when it is on.
        KeyBinding(
            .character("a"), [.command, .shift], .local(.toggleKeepAwake), hint: "awake",
            menu: "Keep Awake"),
        // ⌘⇧J — jump to the agent waiting on you longest; again for the next (M1, #357).
        // benchd decides who waits, from each agent's own report and what its screen shows.
        KeyBinding(
            .character("j"), [.command, .shift], .verb(.focusWaiting), hint: "waiting",
            menu: "Go to Waiting Agent"),
    ]

    /// No hint (`KeyHint`'s header says why), but every one keeps a menu item or a key.
    ///
    /// Not in a browser pane: there the same chords zoom the page (`pageZoom`, #544), since a
    /// browser pane has no terminal font to change.
    private static let fontSize: [KeyBinding] = [
        KeyBinding(
            .character("="), .command, .local(.adjustFontSize(.increase)),
            when: .awayFromBrowser),
        // ⌘+ and ⌘⇧= are the other two ways ⌘+ is typed: `charactersIgnoringModifiers` keeps
        // shift applied. The menu item sits on ⌘+ because a menu prints the row's own chord,
        // and ⌘+ is how every macOS app names this one.
        KeyBinding(
            .character("+"), .command, .local(.adjustFontSize(.increase)),
            when: .awayFromBrowser, menu: "Increase Font Size"),
        KeyBinding(
            .character("+"), [.command, .shift], .local(.adjustFontSize(.increase)),
            when: .awayFromBrowser),
        KeyBinding(
            .character("-"), .command, .local(.adjustFontSize(.decrease)),
            when: .awayFromBrowser, menu: "Decrease Font Size"),
        KeyBinding(
            .character("0"), .command, .local(.adjustFontSize(.reset)),
            when: .awayFromBrowser, menu: "Reset Font Size"),
    ]

    /// The font-size chords in a browser pane: Chrome's zoom. No menu items, for the browser
    /// keys' reason: a menu item fires wherever the keyboard is.
    private static let pageZoom: [KeyBinding] = [
        ("=", NSEvent.ModifierFlags.command, FontSizeStep.increase),
        ("+", .command, .increase), ("+", [.command, .shift], .increase),
        ("-", .command, .decrease), ("0", .command, .reset),
    ].map { key, modifiers, step in
        KeyBinding(
            .character(key), modifiers, .local(.browser(.zoom(step))), when: .browserFocused,
            hint: "zoom")
    }

    /// Whether helm binds a chord somewhere, but no row fires it where the keyboard is now
    /// (#548). ⌘K in a browser pane is one: the page's, so the page surface sends it to the page
    /// before the menu mirror of its row (`KeyBindingMenu`) can claim it, since a menu item
    /// fires wherever the keyboard is. A chord helm never binds (⌘Q, ⌘C) answers false and goes
    /// to the menu as ever.
    static func bindsElsewhere(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        focus: KeyFocus, in table: [KeyBinding]
    ) -> Bool {
        func fires(_ elsewhere: KeyFocus) -> Bool {
            match(
                characters: characters, keyCode: keyCode, modifiers: modifiers,
                focus: elsewhere, in: table) != nil
        }
        return !fires(focus)
            && [KeyFocus.terminal, .browser, .other].contains { $0 != focus && fires($0) }
    }

    /// The row a keystroke fires, if any.
    ///
    /// Pure on purpose — `focus` is passed in rather than read from the first responder, so
    /// the whole table is exercisable from `swift test` with no window, no ghostty runtime and
    /// no focus to simulate.
    static func match(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        focus: KeyFocus, in table: [KeyBinding]
    ) -> KeyBinding? {
        table.first { row in
            guard row.modifiers == modifiers, row.canFire(focus)
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
