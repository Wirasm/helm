import Foundation
import HelmWire

/// One line of the command palette (#500): what it is called, the key that does the same, and
/// what running it does.
struct Command: Equatable {
    let title: String
    /// Where it applies, when the title alone is ambiguous: a pane's workspace.
    var detail: String?
    /// The chord that does the same, rendered from the table. nil when no key does.
    var keys: String?
    let run: Run

    enum Run: Equatable {
        /// A row's action, carried out exactly as its key would (`Actions.perform`).
        case action(KeyBinding.Action)
        /// Verbs sent in order through the bench's one door, as the operator.
        case verbs([BenchVerb])
    }
}

/// Everything the palette offers, derived and never listed.
///
/// **Four sources, none written down here.** The key table in force (every distinct action, so
/// the operator's `keymap.toml` rows are in it), the open workspaces, every pane in benchd's
/// document, and the recipes in the bench justfile. A new key, workspace, pane or recipe is in
/// the palette because it exists, and the palette runs it through the same doors a key does.
///
/// The two index-based gestures, "tab N" and "workspace N", are left out as themselves: the
/// palette names the workspace and the pane instead, and shows the key beside it.
enum CommandList {
    /// `liveTitle` is what a terminal's tab shows, from its live session; nil for a pane with no
    /// live session, which is every terminal in a workspace not drawn since launch.
    static func of(
        table: [KeyBinding], document: BenchDocument?, recipes: [String],
        liveTitle: (BenchDocument.Pane) -> String? = { _ in nil }
    ) -> [Command] {
        actions(table) + workspaces(document, table: table)
            + panes(document, liveTitle: liveTitle) + just(recipes, table: table)
    }

    /// One line per distinct action, in table order, titled by the first row that has a menu
    /// title, else by the action's own title.
    private static func actions(_ table: [KeyBinding]) -> [Command] {
        var seen: [KeyBinding.Action] = []
        return table.compactMap { row in
            guard !seen.contains(row.action), !isIndexed(row.action),
                row.action != .local(.toggleCommandPalette)
            else { return nil }
            seen.append(row.action)
            let rows = table.filter { $0.action == row.action }
            return Command(
                title: rows.lazy.compactMap(\.menu).first ?? row.action.title,
                keys: keys(for: row.action, in: table), run: .action(row.action))
        }
    }

    /// The chord to show beside a line: one that fires wherever the keyboard is, when the table
    /// has one (⌥⌘1 rather than ⌃1, which a focused shell keeps as a control code).
    private static func keys(for action: KeyBinding.Action, in table: [KeyBinding]) -> String? {
        let rows = table.filter { $0.action == action }
        return KeyGlyph.binding(
            for: action,
            in: rows.filter { $0.when == .anywhere }.isEmpty
                ? rows : rows.filter { $0.when == .anywhere })
    }

    private static func isIndexed(_ action: KeyBinding.Action) -> Bool {
        switch action {
        case .verb(.showTab), .verb(.activateWorkspace): true
        default: false
        }
    }

    private static func workspaces(_ document: BenchDocument?, table: [KeyBinding]) -> [Command] {
        guard let document else { return [] }
        return document.workspaces.enumerated().map { index, workspace in
            Command(
                title: "Workspace " + Workspace(path: workspace.path).name,
                keys: keys(for: .verb(.activateWorkspace(index: index)), in: table),
                run: .verbs([.workspaceActivate(path: workspace.path)]))
        }
    }

    /// Every pane of every workspace: going there activates its workspace when it is not the
    /// one on screen, shows its tab and moves the keyboard to its slot. A pane in another
    /// workspace says which.
    private static func panes(
        _ document: BenchDocument?, liveTitle: (BenchDocument.Pane) -> String?
    ) -> [Command] {
        guard let document else { return [] }
        return document.workspaces.flatMap { workspace in
            let here = workspace.path == document.active
            let activate: [BenchVerb] = here ? [] : [.workspaceActivate(path: workspace.path)]
            var untitled = 0
            return workspace.bench.columns.flatMap(\.slots).flatMap { slot in
                slot.panes.map { pane in
                    let known = title(of: pane, live: liveTitle(pane))
                    if known == nil { untitled += 1 }
                    return Command(
                        title: known ?? "terminal \(untitled)",
                        detail: here ? nil : Workspace(path: workspace.path).name,
                        run: .verbs(activate + [.paneShow(pane.id), .focusSlot(slot.id)]))
                }
            }
        }
    }

    /// A pane's line: its name, else what its tab would show. nil for a terminal with no name,
    /// no live session (its workspace not drawn since launch) and no agent: the caller numbers
    /// those `terminal N` in their workspace, counting only them, so two such shells are two
    /// lines. `terminal`, not `shell`, because a live tab's own `shell N` is numbered app-wide
    /// and the two must never print the same label.
    static func title(of pane: BenchDocument.Pane, live: String?) -> String? {
        if let name = pane.name.text { return name }
        switch pane.surface {
        case let .terminal(agent, _): return live ?? agent?.command
        case let .canvas(path): return (path as NSString).lastPathComponent
        case .browser: return "browser"
        case .sessions: return "sessions"
        case let .unsupported(kind): return kind
        }
    }

    /// The justfile's recipes that no key already runs; a bound one is already a line above.
    private static func just(_ recipes: [String], table: [KeyBinding]) -> [Command] {
        recipes.map { KeyBinding.Action.just(recipe: $0) }
            .filter { action in !table.contains { $0.action == action } }
            .map { Command(title: $0.title, run: .action($0)) }
    }
}

extension KeyBinding.Action {
    /// What the palette calls an action no row gives a menu title. Exhaustive, so a new action
    /// does not compile until it has a name the operator can search for.
    var title: String {
        switch self {
        case let .verb(template): template.title
        case let .local(action): action.title
        case let .just(recipe): "just " + recipe
        }
    }
}

extension VerbTemplate {
    var title: String {
        switch self {
        case .newTerminal: "New Terminal"
        case let .split(direction): "Split \(direction.rawValue.capitalized)"
        case .closeFocused: "Close Pane"
        case let .showTab(index): "Show Tab \(index + 1)"
        case let .stepFocus(direction): "Focus \(direction.rawValue.capitalized)"
        case let .moveFocused(direction): "Move Pane \(direction.rawValue.capitalized)"
        case let .activateWorkspace(index): "Workspace \(index + 1)"
        case let .cycleWorkspace(delta): delta < 0 ? "Previous Workspace" : "Next Workspace"
        case let .toggleDrawer(name, _): "Drawer \(name)"
        }
    }
}

extension LocalAction {
    var title: String {
        switch self {
        case .adjustFontSize(.increase): "Increase Font Size"
        case .adjustFontSize(.decrease): "Decrease Font Size"
        case .adjustFontSize(.reset): "Reset Font Size"
        case let .jumpToPrompt(offset): offset < 0 ? "Previous Prompt" : "Next Prompt"
        case .openWorkspacePanel: "Open Workspace…"
        case .openArtifactPanel: "Open Artifact…"
        case .toggleRail: "Toggle Archon Rail"
        case .newNote: "New Note"
        case .toggleKeepAwake: "Keep Awake"
        case .toggleZoom: "Zoom Pane"
        case .toggleCommandPalette: "Command Palette"
        }
    }
}
