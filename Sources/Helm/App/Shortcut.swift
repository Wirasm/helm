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
    let notification: Notification.Name
    /// Posted as the notification's `object`. nil for the payload-less commands.
    let payload: Int?
    /// Set instead of `payload` on the focus-movement rows.
    let direction: Workbench.Direction?
    let focus: Focus
    /// Present when the shortcut also appears in the menu bar, which is both a
    /// discoverability surface and the mouse-only route to the same command.
    let menu: MenuEntry?

    /// What is actually posted as the notification's `object`: the payload index, or a
    /// direction's raw value. Two fields rather than one `Any` so the table stays
    /// `Equatable`-friendly and a test can assert what a row sends.
    var object: Any? { direction?.rawValue ?? payload }

    struct MenuEntry {
        let title: String
        let key: KeyEquivalent
        let modifiers: EventModifiers
    }

    init(
        _ trigger: Trigger, _ modifiers: NSEvent.ModifierFlags,
        posts notification: Notification.Name,
        payload: Int? = nil, direction: Workbench.Direction? = nil,
        focus: Focus = .anywhere, menu: MenuEntry? = nil
    ) {
        self.trigger = trigger
        self.modifiers = modifiers
        self.notification = notification
        self.payload = payload
        self.direction = direction
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
            .keyCode(126), .command, posts: .helmJumpToPrompt, payload: -1, focus: .terminalOnly,
            menu: .init(title: "Jump to Previous Prompt", key: .upArrow, modifiers: .command)),
        Shortcut(
            .keyCode(125), .command, posts: .helmJumpToPrompt, payload: 1, focus: .terminalOnly,
            menu: .init(title: "Jump to Next Prompt", key: .downArrow, modifiers: .command)),
    ]

    /// Mission Control's bindings, when the operator has handed them over. Never
    /// stolen from a focused shell.
    private static let workspaceScoped: [Shortcut] =
        (1...9).map { index in
            Shortcut(
                .character("\(index)"), .control, posts: .helmSelectWorkspace, payload: index - 1,
                focus: .awayFromTerminal)
        }
        + [
            Shortcut(
                .keyCode(123), .control, posts: .helmCycleWorkspace, payload: -1,
                focus: .awayFromTerminal),
            Shortcut(
                .keyCode(124), .control, posts: .helmCycleWorkspace, payload: 1,
                focus: .awayFromTerminal),
        ]

    private static let global: [Shortcut] =
        (1...9).map { index in
            // ⌘⌥1–⌘⌥9 — the fallback that needs no System Settings change.
            Shortcut(
                .character("\(index)"), [.command, .option], posts: .helmSelectWorkspace,
                payload: index - 1)
        }
        + (1...9).map { index in
            // ⌘1–⌘9 — select terminal by tab position (1-based keys, 0-based index).
            Shortcut(
                .character("\(index)"), .command, posts: .helmSelectTerminal, payload: index - 1)
        }
        + [
            // ⌘⇧= is how ⌘+ is actually typed: charactersIgnoringModifiers keeps shift
            // applied, so the bare-⌘ row below never sees it.
            Shortcut(
                .character("+"), [.command, .shift], posts: .helmAdjustFontSize,
                payload: FontSizeStep.increase.rawValue),
            // ⌘⇧O — open a folder as a workspace. `charactersIgnoringModifiers` keeps
            // shift applied so this arrives uppercase; matching is case-insensitive
            // (see `match`), and the modifier set is what separates it from ⌘O.
            Shortcut(
                .character("o"), [.command, .shift], posts: .helmOpenWorkspace,
                menu: .init(title: "Open Workspace…", key: "o", modifiers: [.command, .shift])),
            Shortcut(
                .character("="), .command, posts: .helmAdjustFontSize,
                payload: FontSizeStep.increase.rawValue,
                menu: .init(title: "Increase Font Size", key: "+", modifiers: .command)),
            Shortcut(
                .character("+"), .command, posts: .helmAdjustFontSize,
                payload: FontSizeStep.increase.rawValue),
            Shortcut(
                .character("-"), .command, posts: .helmAdjustFontSize,
                payload: FontSizeStep.decrease.rawValue,
                menu: .init(title: "Decrease Font Size", key: "-", modifiers: .command)),
            Shortcut(
                .character("0"), .command, posts: .helmAdjustFontSize,
                payload: FontSizeStep.reset.rawValue,
                menu: .init(title: "Reset Font Size", key: "0", modifiers: .command)),
            Shortcut(
                .character("n"), .command, posts: .helmNewTerminal,
                menu: .init(title: "New Terminal", key: "n", modifiers: .command)),
            // ⌘T — swap the pane between the terminal and the agent's writing.
            // `.anywhere` because the terminal grid holds focus almost all the
            // time and this has to work from there; the local monitor consumes
            // it, so ghostty's own ⌘T (new tab) never sees it.
            Shortcut(
                .character("t"), .command, posts: .helmToggleChat,
                menu: .init(title: "Toggle Chat View", key: "t", modifiers: .command)),
            Shortcut(
                .character("o"), .command, posts: .helmOpenArtifact,
                menu: .init(title: "Open Artifact…", key: "o", modifiers: .command)),
            // ⌘L — the address bar, wherever the idiom comes from. Payload-less:
            // the canvas focuses its field and the operator types.
            Shortcut(
                .character("l"), .command, posts: .helmOpenCanvasURL,
                menu: .init(title: "Open URL…", key: "l", modifiers: .command)),
            Shortcut(
                .character("r"), [.command, .shift], posts: .helmToggleRail,
                menu: .init(title: "Toggle Archon Rail", key: "r", modifiers: [.command, .shift])),
            // ⌘⇧D before ⌘D: `match` returns the FIRST row whose modifier set compares
            // equal, and while these two cannot collide (the sets differ), keeping the
            // more-specific one first is the habit that stops the next pair colliding.
            Shortcut(
                .character("d"), [.command, .shift], posts: .helmSplitDown,
                menu: .init(title: "Split Down", key: "d", modifiers: [.command, .shift])),
            Shortcut(
                .character("d"), .command, posts: .helmSplitRight,
                menu: .init(title: "Split Right", key: "d", modifiers: .command)),
            // ⌘⌥W, because ⌘W is not available: SwiftUI's `WindowGroup` binds it to
            // close-window and helm would be fighting its own shell for it.
            Shortcut(
                .character("w"), [.command, .option], posts: .helmClosePane,
                menu: .init(title: "Close Pane", key: "w", modifiers: [.command, .option])),
        ] + focusMovement

    /// ⌘⌥ + arrows, because ⌘⌥1–9 is already the workspace fallback. The payload is a
    /// `Workbench.Direction` raw value rather than an Int: the map carries `payload: Int?`
    /// for tab and workspace indices, and a direction is not an index.
    private static let focusMovement: [Shortcut] = [
        (123, Workbench.Direction.left, KeyEquivalent.leftArrow, "Left"),
        (124, .right, .rightArrow, "Right"),
        (126, .up, .upArrow, "Up"),
        (125, .down, .downArrow, "Down"),
    ].map { keyCode, direction, key, name in
        Shortcut(
            .keyCode(keyCode), [.command, .option], posts: .helmMoveFocus,
            direction: direction,
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
