import Foundation
import HelmWire

/// The names the keymap file gives actions, and the one argument each may take.
///
/// **One switch in each direction.** `spelled` is exhaustive, so a new `VerbTemplate` or
/// `LocalAction` case does not compile until it has a name; `KeymapFileTests` renders every
/// built-in row and parses it back, so a name that does not parse fails there.
extension KeyBinding.Action {
    var spelled: (name: String, arguments: KeymapArguments) {
        switch self {
        case let .verb(template): template.spelled
        case let .local(action): action.spelled
        case let .just(recipe): ("just", .init(recipe: recipe))
        }
    }

    init(name: String, arguments: KeymapArguments) throws(KeymapProblem) {
        if name == "just" {
            self = .just(recipe: try arguments.recipe(name))
        } else if let template = try VerbTemplate(name: name, arguments: arguments) {
            self = .verb(template)
        } else if let action = try LocalAction(name: name, arguments: arguments) {
            self = .local(action)
        } else {
            throw KeymapProblem(line: nil, reason: "unknown action '\(name)'")
        }
    }
}

extension VerbTemplate {
    var spelled: (name: String, arguments: KeymapArguments) {
        switch self {
        case .newTerminal: ("new-terminal", .none)
        case let .split(direction): ("split", .init(direction: direction.rawValue))
        case .closeFocused: ("close-pane", .none)
        case let .showTab(index): ("show-tab", .init(index: index + 1))
        case let .stepFocus(direction): ("focus", .init(direction: direction.rawValue))
        case let .moveFocused(direction): ("move-pane", .init(direction: direction.rawValue))
        case let .activateWorkspace(index): ("workspace", .init(index: index + 1))
        case let .cycleWorkspace(delta): ("cycle-workspace", .init(delta: delta))
        case let .toggleDrawer(name, surface):
            ("drawer", .init(name: name, surface: surface?.keymapSpelling))
        }
    }

    /// nil when `name` is not a bench gesture; a refusal when it is and its argument is wrong.
    init?(name: String, arguments a: KeymapArguments) throws(KeymapProblem) {
        switch name {
        case "new-terminal": try a.none(name); self = .newTerminal
        case "split": self = .split(try a.direction(BenchSplit.self, name))
        case "close-pane": try a.none(name); self = .closeFocused
        case "show-tab": self = .showTab(index: try a.index(name))
        case "focus": self = .stepFocus(try a.direction(BenchDirection.self, name))
        case "move-pane": self = .moveFocused(try a.direction(BenchDirection.self, name))
        case "workspace": self = .activateWorkspace(index: try a.index(name))
        case "cycle-workspace": self = .cycleWorkspace(delta: try a.delta(name))
        case "drawer":
            let drawer = try a.drawer(name)
            self = .toggleDrawer(name: drawer.name, surface: drawer.surface)
        default: return nil
        }
    }
}

extension LocalAction {
    var spelled: (name: String, arguments: KeymapArguments) {
        switch self {
        case let .adjustFontSize(step): ("font-size", .init(step: step.spelled))
        case let .jumpToPrompt(offset): ("jump-to-prompt", .init(offset: offset))
        case .openWorkspacePanel: ("open-workspace-panel", .none)
        case .openArtifactPanel: ("open-artifact-panel", .none)
        case .toggleRail: ("toggle-rail", .none)
        case .newNote: ("new-note", .none)
        }
    }

    init?(name: String, arguments a: KeymapArguments) throws(KeymapProblem) {
        switch name {
        case "font-size": self = .adjustFontSize(try a.step(name))
        case "jump-to-prompt": self = .jumpToPrompt(offset: try a.offset(name))
        case "open-workspace-panel": try a.none(name); self = .openWorkspacePanel
        case "open-artifact-panel": try a.none(name); self = .openArtifactPanel
        case "toggle-rail": try a.none(name); self = .toggleRail
        case "new-note": try a.none(name); self = .newNote
        default: return nil
        }
    }
}

extension Surface {
    /// What a drawer key starts an empty drawer with, as the file spells it.
    fileprivate init?(keymapSpelling text: String) {
        if text == "browser" {
            self = .browser
        } else if text == "sessions" {
            self = .sessions
        } else if text.hasPrefix("file:"), text.count > "file:".count {
            self = .canvas(
                path: (String(text.dropFirst("file:".count)) as NSString)
                    .expandingTildeInPath)
        } else {
            return nil
        }
    }

    /// The inverse, for rendering. A surface no key can name (a terminal, a kind this build does
    /// not know) is spelled by its kind, which the parser then refuses.
    fileprivate var keymapSpelling: String {
        switch self {
        case .browser: "browser"
        case .sessions: "sessions"
        case let .canvas(path): "file:" + path
        case .terminal: "terminal"
        case let .unsupported(kind): kind
        }
    }
}

extension FontSizeStep {
    fileprivate var spelled: String {
        switch self {
        case .increase: "increase"
        case .decrease: "decrease"
        case .reset: "reset"
        }
    }
}

/// An action's argument, as a row carries it: at most one of these is set, and which one is
/// the action's to say. `index` is 1-based in the file, as the keys that use it are.
struct KeymapArguments: Equatable {
    var direction: String?
    var index: Int?
    var delta: Int?
    var step: String?
    var offset: Int?
    /// A drawer's name, and what it starts with when it holds nothing yet (`drawer`).
    var name: String?
    var surface: String?
    /// A recipe in `<bench root>/rules/justfile` (`just`). benchd judges the name.
    var recipe: String?

    static let none = KeymapArguments()
    static let fields = [
        "direction", "index", "delta", "step", "offset", "name", "surface", "recipe",
    ]

    /// The row's argument line, empty for none.
    var rendered: [String] {
        [
            direction.map { "direction = \"\($0)\"" }, index.map { "index = \($0)" },
            delta.map { "delta = \($0)" }, step.map { "step = \"\($0)\"" },
            offset.map { "offset = \($0)" }, name.map { "name = \"\($0)\"" },
            surface.map { "surface = \"\($0)\"" }, recipe.map { "recipe = \"\($0)\"" },
        ].compactMap(\.self)
    }

    private var present: [String] {
        let set = [
            direction != nil, index != nil, delta != nil, step != nil, offset != nil,
            name != nil, surface != nil, recipe != nil,
        ]
        return zip(Self.fields, set).filter(\.1).map(\.0)
    }

    /// Refuses any argument but `fields`.
    private func only(_ fields: [String], _ action: String) throws(KeymapProblem) {
        if let extra = present.first(where: { !fields.contains($0) }) {
            let takes =
                fields.isEmpty ? "no argument" : "only " + fields.joined(separator: " and ")
            throw KeymapProblem(line: nil, reason: "'\(action)' takes \(takes), not \(extra)")
        }
    }

    private func only(_ field: String, _ action: String) throws(KeymapProblem) {
        try only([field], action)
    }

    private func missing(_ field: String, _ action: String) -> KeymapProblem {
        KeymapProblem(line: nil, reason: "'\(action)' needs \(field)")
    }

    func none(_ action: String) throws(KeymapProblem) { try only([], action) }

    func recipe(_ action: String) throws(KeymapProblem) -> String {
        try only("recipe", action)
        guard let recipe, !recipe.isEmpty else { throw missing("recipe", action) }
        return recipe
    }

    /// A drawer's name, and the surface it starts with if it is empty: `browser`, `sessions`, or
    /// `file:<path>` for a canvas.
    func drawer(_ action: String) throws(KeymapProblem) -> (name: String, surface: Surface?) {
        try only(["name", "surface"], action)
        guard let name, !name.isEmpty else { throw missing("name", action) }
        guard DrawerStyle.isDrawerName(name) else {
            throw KeymapProblem(
                line: nil, reason: "'\(action)' name '\(name)': \(DrawerStyle.nameRule)")
        }
        guard let surface else { return (name, nil) }
        guard let parsed = Surface(keymapSpelling: surface) else {
            throw KeymapProblem(
                line: nil,
                reason:
                    "'\(action)' surface is browser, sessions or file:<path>, not '\(surface)'")
        }
        return (name, parsed)
    }

    func direction<Value: RawRepresentable<String>>(
        _: Value.Type, _ action: String
    )
        throws(KeymapProblem) -> Value
    {
        try only("direction", action)
        guard let direction else { throw missing("direction", action) }
        guard let value = Value(rawValue: direction) else {
            throw KeymapProblem(
                line: nil, reason: "'\(action)' cannot take direction '\(direction)'")
        }
        return value
    }

    /// 0-based, from the file's 1-based.
    func index(_ action: String) throws(KeymapProblem) -> Int {
        try only("index", action)
        guard let index else { throw missing("index", action) }
        guard index >= 1 else {
            throw KeymapProblem(line: nil, reason: "'\(action)' index starts at 1, not \(index)")
        }
        return index - 1
    }

    func delta(_ action: String) throws(KeymapProblem) -> Int {
        try only("delta", action)
        guard let delta, delta != 0 else { throw missing("a delta other than 0", action) }
        return delta
    }

    func offset(_ action: String) throws(KeymapProblem) -> Int {
        try only("offset", action)
        guard let offset, offset != 0 else { throw missing("an offset other than 0", action) }
        return offset
    }

    func step(_ action: String) throws(KeymapProblem) -> FontSizeStep {
        try only("step", action)
        guard let step else { throw missing("step", action) }
        guard let value = FontSizeStep.allCases.first(where: { $0.spelled == step }) else {
            throw KeymapProblem(
                line: nil, reason: "'\(action)' step is increase, decrease or reset, not '\(step)'")
        }
        return value
    }
}
