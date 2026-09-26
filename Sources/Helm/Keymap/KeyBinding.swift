import AppKit
import HelmWire
import SwiftUI

// MARK: - KeyBinding

/// One row of the key table: a chord, when it may fire, what it does, and how it is shown.
///
/// **The table is the one place a key is defined** (M4 PR 3b of #354). The keymap monitor
/// matches chords against it, the menu is built from the rows that have a `menu`, and the
/// status bar's hints come from the rows that have a `hint`. It replaces `HelmCommand`, its
/// NotificationCenter bus, `Shortcut`, `HelmCommands` and `KeyHintCatalog`: five places that had
/// to agree about one key.
///
/// **An action is data, not a closure**, so the table loads from the operator's keymap file by
/// name (`KeymapFile`, #356). A `.verb` action is a gesture on the bench and becomes a
/// `BenchVerb` sent through `WorkbenchModel.send` as the operator; a `.local` action never reaches the
/// document.
struct KeyBinding: Equatable {
    let trigger: Trigger
    let modifiers: NSEvent.ModifierFlags
    let when: When
    let action: Action
    /// The label on the status bar. Rows sharing a label are shown as one hint.
    let hint: String?
    /// The menu item's title. Its shortcut is the row's own chord (`menuShortcut`), so a row
    /// cannot show one key in the menu and fire on another.
    let menu: String?

    init(
        _ trigger: Trigger, _ modifiers: NSEvent.ModifierFlags, _ action: Action,
        when: When = .anywhere, hint: String? = nil, menu: String? = nil
    ) {
        self.trigger = trigger
        self.modifiers = modifiers
        self.when = when
        self.action = action
        self.hint = hint
        self.menu = menu
    }

    enum Trigger: Equatable {
        /// Matched against `charactersIgnoringModifiers`, case-insensitively: a shifted letter
        /// arrives uppercase, and the modifier set is what tells ⌘O from ⌘⇧O.
        case character(String)
        case keyCode(UInt16)
    }

    /// Where the operator's keyboard is when the chord may fire. The reason the table cannot be
    /// a dictionary: ⌃3 switches workspace outside a terminal and must reach a focused shell as
    /// a control code inside one.
    enum When: Equatable {
        case anywhere
        case terminalFocused
        case awayFromTerminal
    }

    enum Action: Equatable {
        case verb(VerbTemplate)
        case local(LocalAction)
        /// A recipe from the operator's bench justfile, run by benchd as him (#356).
        case just(recipe: String)
    }

    /// The chord as a menu prints it. nil for a key code the menu has no equivalent for, which
    /// leaves the item clickable and the key still bound.
    var menuShortcut: KeyboardShortcut? {
        let key: KeyEquivalent
        switch trigger {
        case let .character(character):
            guard let only = character.first, character.count == 1 else { return nil }
            key = KeyEquivalent(only)
        case .keyCode:
            guard let arrow = ArrowKey(trigger) else { return nil }
            key = arrow.keyEquivalent
        }
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return KeyboardShortcut(key, modifiers: flags)
    }

    func canFire(terminalFocused: Bool) -> Bool {
        switch when {
        case .anywhere: true
        case .terminalFocused: terminalFocused
        case .awayFromTerminal: !terminalFocused
        }
    }
}

// MARK: - The actions

/// A gesture on the bench, named. It becomes a `BenchVerb` when it fires, resolved against the
/// bench as it is at that moment — "the focused pane", "the third tab of the focused slot" — so
/// the table itself holds no ids.
enum VerbTemplate: Equatable {
    case newTerminal
    case split(BenchSplit)
    case closeFocused
    case showTab(index: Int)
    case stepFocus(BenchDirection)
    case moveFocused(BenchDirection)
    case activateWorkspace(index: Int)
    case cycleWorkspace(delta: Int)
    /// Show a drawer over the bench, or hide it (#356). `surface` is what an empty drawer
    /// starts with; benchd refuses to open an empty drawer without one.
    case toggleDrawer(name: String, surface: Surface?)

    /// The verb this gesture means on `bench`, with `workspaces` open and `active` on screen.
    /// nil when it means nothing right now: no focused pane, no tab at that index, one workspace
    /// to cycle through.
    func resolve(
        bench: Workbench?, workspaces: [WorkspacePath], active: WorkspacePath?
    ) -> BenchVerb? {
        switch self {
        case .newTerminal: return .paneOpen(surface: .terminal(agent: nil))
        case let .split(direction): return .paneSplit(direction: direction)
        case .closeFocused:
            return bench?.focusedPane.map { .paneClose($0.id) }
        case let .showTab(index):
            guard let bench, let slot = bench.slot(bench.focusedSlot),
                slot.panes.indices.contains(index)
            else { return nil }
            return .paneShow(slot.panes[index].id)
        case let .stepFocus(direction): return .focusStep(direction: direction)
        case let .moveFocused(direction):
            return bench?.focusedPane.map { .paneMove($0.id, direction) }
        case let .activateWorkspace(index):
            guard workspaces.indices.contains(index) else { return nil }
            return .workspaceActivate(path: workspaces[index].value)
        case let .cycleWorkspace(delta):
            guard !workspaces.isEmpty else { return nil }
            let current = active.flatMap { workspaces.firstIndex(of: $0) } ?? 0
            let next = (current + delta + workspaces.count) % workspaces.count
            return .workspaceActivate(path: workspaces[next].value)
        case let .toggleDrawer(name, surface): return .drawerToggle(name: name, surface: surface)
        }
    }
}

/// What a key does that never reaches the bench document.
enum LocalAction: Equatable {
    case adjustFontSize(FontSizeStep)
    /// ⌘↑/⌘↓: jump between shell prompt marks (OSC 133) — between turns, in an agent session.
    case jumpToPrompt(offset: Int)
    /// The folder panel; the folder chosen becomes a `workspace/open`.
    case openWorkspacePanel
    /// The artifact popover; the file chosen becomes a `pane/open`.
    case openArtifactPanel
    case toggleRail
    /// Writes a dated note file, then opens it with a `pane/open`.
    case newNote
}
