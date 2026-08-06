import AppKit
import SwiftUI

/// helm's keyboard map, as data.
///
/// It used to be written **twice** — once as a switch inside a local `NSEvent`
/// monitor and again as menu buttons with their own `keyboardShortcut` modifiers —
/// which meant nine shortcuts existed in two places that had to be kept in step by
/// hand, and every feature adding one edited the same file in three spots.
///
/// One table, two consumers: `Keymap` matches raw key events against it, and
/// `HelmCommands` builds the menu from the rows that opt in. A vertical adds a
/// shortcut by adding a row — and because `match` is a pure function over values,
/// the map is testable without a window, which the switch never was.
struct Shortcut {
    /// What the key event has to look like. Arrow keys carry function-key code
    /// points rather than typable characters, so they match on `keyCode`.
    enum Trigger: Equatable {
        case character(String)
        case keyCode(UInt16)
    }

    /// Whether the shortcut may fire while the terminal grid holds keyboard focus.
    ///
    /// This is the whole reason the map cannot be a plain dictionary. helm's frame
    /// keeps text fields alongside an always-visible terminal, so ⌘↑/⌘↓ must keep
    /// its text-navigation meaning outside the terminal, and legacy ⌃1–⌃9 control
    /// codes belong to a focused shell rather than to workspace switching.
    enum Focus: Equatable {
        /// Fires regardless of what holds focus.
        case anywhere
        /// Only while the terminal grid has focus — otherwise the event passes through.
        case terminalOnly
        /// Only while it does not — otherwise the event passes through to the shell.
        case awayFromTerminal
    }

    let trigger: Trigger
    let modifiers: NSEvent.ModifierFlags
    /// What this row does, payload and all.
    ///
    /// **One field where there were three.** It was `notification` + `payload: Int?` +
    /// `direction: Workbench.Direction?`, plus a computed `object: Any?` to choose between the
    /// last two — because the channel took `Any?` and a row had to pre-flatten itself to fit.
    /// A direction now travels as a direction; see `HelmCommand`, and #152 for what the
    /// flattening cost.
    let command: HelmCommand
    let focus: Focus
    /// Present when the shortcut also appears in the menu bar, which is both a
    /// discoverability surface and the mouse-only route to the same command.
    let menu: MenuEntry?

    /// Fire this row's command.
    ///
    /// Still the one place a row is turned into a posted command, and now there is nothing left
    /// to pair: the payload is *inside* the command, so the two consumers cannot assemble it
    /// differently. #152 was the menu posting `payload` (nil on all four focus rows) while the
    /// keymap posted `object`; that shape no longer exists to get wrong.
    func post() {
        command.post()
    }

    struct MenuEntry {
        let title: String
        let key: KeyEquivalent
        let modifiers: EventModifiers
    }

    init(
        _ trigger: Trigger, _ modifiers: NSEvent.ModifierFlags,
        does command: HelmCommand,
        focus: Focus = .anywhere, menu: MenuEntry? = nil
    ) {
        self.trigger = trigger
        self.modifiers = modifiers
        self.command = command
        self.focus = focus
        self.menu = menu
    }
}

extension Shortcut {
    /// Every shortcut helm binds, in match order.
    ///
    /// Order matters where triggers overlap: the focus-conditional rows come first so
    /// a focused terminal keeps its own control codes, and the ⌘⌥ workspace row exists
    /// as the always-available fallback for operators who have not released Mission
    /// Control's ⌃1–⌃9 in System Settings.
    ///
    /// **⌘T is the two faces of the terminal pane, back where the muscle memory
    /// already is.** It was freed when the one-surface re-layout killed the old
    /// two-faces model, and reserved rather than reused; the chat face claims it
    /// deliberately, being the same shape of command. **⌘J is still unbound** —
    /// reserved for terminal maximize. Muscle memory lives here.
    static let all: [Shortcut] = terminalScoped + workspaceScoped + global

    /// Rows that a focused terminal wins or loses outright.
    private static let terminalScoped: [Shortcut] = [
        // ⌘↑/⌘↓ — jump between shell prompt marks (OSC 133). In an agent session each
        // turn leaves a mark, so this is effectively jump-between-turns.
        Shortcut(
            .keyCode(126), .command, does: .jumpToPrompt(offset: -1), focus: .terminalOnly,
            menu: .init(title: "Jump to Previous Prompt", key: .upArrow, modifiers: .command)),
        Shortcut(
            .keyCode(125), .command, does: .jumpToPrompt(offset: 1), focus: .terminalOnly,
            menu: .init(title: "Jump to Next Prompt", key: .downArrow, modifiers: .command)),
    ]

    /// Mission Control's bindings, when the operator has handed them over. Never
    /// stolen from a focused shell.
    private static let workspaceScoped: [Shortcut] =
        (1...9).map { index in
            Shortcut(
                .character("\(index)"), .control, does: .selectWorkspace(index: index - 1),
                focus: .awayFromTerminal)
        }
        + [
            Shortcut(
                .keyCode(123), .control, does: .cycleWorkspace(delta: -1),
                focus: .awayFromTerminal),
            Shortcut(
                .keyCode(124), .control, does: .cycleWorkspace(delta: 1),
                focus: .awayFromTerminal),
        ]

    private static let global: [Shortcut] =
        (1...9).map { index in
            // ⌘⌥1–⌘⌥9 — the fallback that needs no System Settings change.
            Shortcut(
                .character("\(index)"), [.command, .option],
                does: .selectWorkspace(index: index - 1))
        }
        + (1...9).map { index in
            // ⌘1–⌘9 — select terminal by tab position (1-based keys, 0-based index).
            Shortcut(
                .character("\(index)"), .command, does: .selectTerminal(index: index - 1))
        }
        + [
            // ⌘⇧= is how ⌘+ is actually typed: charactersIgnoringModifiers keeps shift
            // applied, so the bare-⌘ row below never sees it.
            Shortcut(
                .character("+"), [.command, .shift], does: .adjustFontSize(.increase)),
            // ⌘⇧O — open a folder as a workspace. `charactersIgnoringModifiers` keeps
            // shift applied so this arrives uppercase; matching is case-insensitive
            // (see `match`), and the modifier set is what separates it from ⌘O.
            Shortcut(
                .character("o"), [.command, .shift], does: .openWorkspace,
                menu: .init(title: "Open Workspace…", key: "o", modifiers: [.command, .shift])),
            Shortcut(
                .character("="), .command, does: .adjustFontSize(.increase),
                menu: .init(title: "Increase Font Size", key: "+", modifiers: .command)),
            Shortcut(
                .character("+"), .command, does: .adjustFontSize(.increase)),
            Shortcut(
                .character("-"), .command, does: .adjustFontSize(.decrease),
                menu: .init(title: "Decrease Font Size", key: "-", modifiers: .command)),
            Shortcut(
                .character("0"), .command, does: .adjustFontSize(.reset),
                menu: .init(title: "Reset Font Size", key: "0", modifiers: .command)),
            Shortcut(
                .character("n"), .command, does: .newTerminal,
                menu: .init(title: "New Terminal", key: "n", modifiers: .command)),
            // ⌘T — swap the pane between the terminal and the agent's writing.
            // `.anywhere` because the terminal grid holds focus almost all the
            // time and this has to work from there; the local monitor consumes
            // it, so ghostty's own ⌘T (new tab) never sees it.
            Shortcut(
                .character("t"), .command, does: .toggleChat,
                menu: .init(title: "Toggle Chat View", key: "t", modifiers: .command)),
            Shortcut(
                .character("o"), .command, does: .openArtifact,
                menu: .init(title: "Open Artifact…", key: "o", modifiers: .command)),
            // ⌘L — the address bar, wherever the idiom comes from. The `nil` URL IS the
            // command: the canvas focuses its field and the operator types. It used to be
            // the *absence* of a notification object, which is the one shape an untyped
            // channel cannot tell from a mistake.
            Shortcut(
                .character("l"), .command, does: .openCanvasURL(nil),
                menu: .init(title: "Open URL…", key: "l", modifiers: .command)),
            Shortcut(
                .character("r"), [.command, .shift], does: .toggleRail,
                menu: .init(title: "Toggle Archon Rail", key: "r", modifiers: [.command, .shift])),
            // ⌘⇧D before ⌘D: `match` returns the FIRST row whose modifier set compares
            // equal, and while these two cannot collide (the sets differ), keeping the
            // more-specific one first is the habit that stops the next pair colliding.
            Shortcut(
                .character("d"), [.command, .shift], does: .splitDown,
                menu: .init(title: "Split Down", key: "d", modifiers: [.command, .shift])),
            Shortcut(
                .character("d"), .command, does: .splitRight,
                menu: .init(title: "Split Right", key: "d", modifiers: .command)),
            // ⌘⌥W, because ⌘W is not available: SwiftUI's `WindowGroup` binds it to
            // close-window and helm would be fighting its own shell for it.
            Shortcut(
                .character("w"), [.command, .option], does: .closePane,
                menu: .init(title: "Close Pane", key: "w", modifiers: [.command, .option])),
        ] + focusMovement

    /// ⌘⌥ + arrows, because ⌘⌥1–9 is already the workspace fallback.
    ///
    /// The direction travels as a `Workbench.Direction`. It used to travel as that direction's
    /// **raw value**, in a second field beside `payload`, because the channel took `Any?` and
    /// the map had to pick one of two boxes to flatten into — see `HelmCommand`.
    private static let focusMovement: [Shortcut] = [
        (123, Workbench.Direction.left, KeyEquivalent.leftArrow, "Left"),
        (124, .right, .rightArrow, "Right"),
        (126, .up, .upArrow, "Up"),
        (125, .down, .downArrow, "Down"),
    ].map { keyCode, direction, key, name in
        Shortcut(
            .keyCode(keyCode), [.command, .option], does: .moveFocus(direction),
            menu: .init(title: "Focus \(name)", key: key, modifiers: [.command, .option]))
    }

    /// Whether this row is live at all, given where focus is.
    ///
    /// Extracted from `match` because it has a second caller that is not about a key event:
    /// the status bar's hints, which have to say ⌃1–9 or ⌘⌥1–9 depending on the same
    /// answer. Asking the map is what keeps the hint honest — a row that stops firing stops
    /// being advertised in the same edit, with nothing to keep in step.
    func canFire(terminalFocused: Bool) -> Bool {
        switch focus {
        case .anywhere: true
        case .terminalOnly: terminalFocused
        case .awayFromTerminal: !terminalFocused
        }
    }

    /// The shortcut a key event fires, or nil to let the event through.
    ///
    /// Pure on purpose — `terminalFocused` is passed in rather than read from
    /// `TerminalManager.shared`, so the whole map is exercisable from `swift test`
    /// with no window, no ghostty runtime and no focus to simulate.
    static func match(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        terminalFocused: Bool
    ) -> Shortcut? {
        all.first { shortcut in
            guard shortcut.modifiers == modifiers else { return false }
            guard shortcut.canFire(terminalFocused: terminalFocused) else { return false }
            switch shortcut.trigger {
            case let .keyCode(code): return code == keyCode
            // Case-insensitive: a shifted letter arrives uppercase, and the modifier
            // set (compared exactly above) is what distinguishes ⌘O from ⌘⇧O.
            case let .character(character):
                return character.lowercased() == characters?.lowercased()
            }
        }
    }
}
