import AppKit
import Foundation
import HelmWire
import TOMLDecoder

// MARK: - The file

/// The operator's keymap file, `<bench root>/rules/keymap.toml` (#356): rows that bind a chord,
/// and chords to unbind.
///
/// ```toml
/// unbind = ["cmd+shift+r"]
///
/// [[bind]]
/// key = "cmd+shift+b"       # cmd ctrl alt shift + a character, plus, left/right/up/down, keycode:N
/// when = "anywhere"         # anywhere (the default) | terminal | away-from-terminal
/// action = "drawer"         # a name from docs/keymap.default.toml, with its arguments
/// name = "browser"
/// hint = "browser"          # the status-bar label, optional
/// menu = "Shared Browser"   # the menu item's title, optional
/// ```
///
/// **It overlays the built-in table rather than replacing it** (`overlay(on:)`), so a file that
/// rebinds one key does not unbind the rest. `docs/keymap.default.toml` is the built-in table in
/// this format; copying it in whole is valid and changes nothing.
///
/// **Strict, because a typo must not be a silent no-op.** An unknown field, action, argument or
/// key refuses the whole file with the line it is on, and `Keymap` keeps the last good table.
struct KeymapFile: Equatable {
    struct Row: Equatable {
        let binding: KeyBinding
        /// The line of the row's `[[bind]]` header, for the refusal to point at.
        let line: Int?
    }

    let rows: [Row]
    let unbind: [KeyChord]
    /// `[drawer.<name>]`: where a drawer sits and how wide it is. A drawer not named here uses
    /// `DrawerStyle.builtIn(for:)`.
    var drawers: [String: DrawerStyle] = [:]

    static func parse(_ text: String) throws(KeymapProblem) -> KeymapFile {
        let raw: RawFile
        do {
            raw = try TOMLDecoder().decode(RawFile.self, from: text)
        } catch let problem as KeymapProblem {
            throw problem
        } catch let row as RowError {
            throw KeymapProblem(
                line: bindHeaderLines(in: text)[safe: row.index], reason: row.reason)
        } catch {
            throw KeymapProblem(line: nil, reason: describe(error))
        }
        let lines = bindHeaderLines(in: text)
        var rows: [Row] = []
        for (index, row) in raw.bind.enumerated() {
            let line = lines[safe: index]
            do {
                rows.append(Row(binding: try row.binding(), line: line))
            } catch {
                throw KeymapProblem(line: line, reason: error.reason)
            }
        }
        var unbind: [KeyChord] = []
        for chord in raw.unbind {
            do { unbind.append(try KeyChord(parsing: chord)) } catch {
                throw KeymapProblem(line: nil, reason: "unbind: \(error.reason)")
            }
        }
        var drawers: [String: DrawerStyle] = [:]
        for (name, style) in raw.drawer {
            guard DrawerStyle.isDrawerName(name) else {
                throw KeymapProblem(line: nil, reason: "[drawer.\(name)]: \(DrawerStyle.nameRule)")
            }
            do { drawers[name] = try style.style(for: name) } catch {
                throw KeymapProblem(line: nil, reason: "[drawer.\(name)]: \(error.reason)")
            }
        }
        return KeymapFile(rows: rows, unbind: unbind, drawers: drawers)
    }

    /// The table this file makes of `defaults`.
    ///
    /// Each row replaces every default with its chord in an overlapping `when`, in that default's
    /// place, so the status bar keeps its order; the rest are appended. `unbind` removes the
    /// defaults with that chord, in any `when`. Unbinding a chord nothing has is not an error:
    /// the file should not start failing because a built-in key was retired.
    ///
    /// The result can never claim one chord twice in overlapping `when`s — the rule
    /// `BindingTableTests` holds the defaults to — because the defaults already cannot, a
    /// default a row overlaps is dropped, and two rows that overlap refuse the file.
    func overlay(on defaults: [KeyBinding]) throws(KeymapProblem) -> [KeyBinding] {
        for (index, row) in rows.enumerated() {
            if let earlier = rows[..<index].first(where: { $0.binding.collides(with: row.binding) })
            {
                throw KeymapProblem(
                    line: row.line,
                    reason: "\(row.binding.chord.spelled) is already bound"
                        + (earlier.line.map { " on line \($0)" } ?? ""))
            }
        }
        var placed = Set<Int>()
        var table: [KeyBinding] = []
        for binding in defaults where !unbind.contains(binding.chord) {
            guard let index = rows.firstIndex(where: { $0.binding.collides(with: binding) }) else {
                table.append(binding)
                continue
            }
            if placed.insert(index).inserted { table.append(rows[index].binding) }
        }
        return table + rows.indices.filter { !placed.contains($0) }.map { rows[$0].binding }
    }

    /// `table` as a keymap file. `docs/keymap.default.toml` is this of `KeyBindings.all`.
    static func render(_ table: [KeyBinding]) -> String {
        let rows = table.map { binding in
            let (name, arguments) = binding.action.spelled
            var lines = ["[[bind]]", "key = \(quoted(binding.chord.spelled))"]
            if binding.when != .anywhere { lines.append("when = \(quoted(binding.when.spelled))") }
            lines.append("action = \(quoted(name))")
            lines += arguments.rendered
            if let hint = binding.hint { lines.append("hint = \(quoted(hint))") }
            if let menu = binding.menu { lines.append("menu = \(quoted(menu))") }
            return lines.joined(separator: "\n")
        }
        return header + rows.joined(separator: "\n\n") + "\n"
    }

    private static let header = """
        # helm's built-in keymap, generated from KeyBindings.all — do not edit this copy.
        #
        # To change a key, write <bench root>/rules/keymap.toml (~/.bench/rules/keymap.toml, or
        # ~/.bench-<suite>/ for an isolated helm). It overlays these rows and reloads live:
        #   - a [[bind]] row replaces the built-in rows with the same key in an overlapping `when`,
        #     or adds a key;
        #   - unbind = ["cmd+shift+r"] removes a built-in key;
        #   - a file that does not parse changes nothing, and the status bar says why.
        # Copying this whole file in is valid and changes nothing.
        #
        # key:    cmd, ctrl, alt, shift joined by + before one character, plus, left, right, up,
        #         down or keycode:N
        # when:   anywhere (the default), terminal, away-from-terminal
        # action: one of the names below; index is 1-based. `drawer` takes name and, optionally,
        #         surface = "browser", "sessions" or "file:<path>" for a drawer that holds nothing.
        #         `just` takes recipe: a recipe in <bench root>/rules/justfile, run by benchd as you
        #
        # A drawer's place is a table of its own, e.g.
        #   [drawer.notes]
        #   edge = "left"             # left or right
        #   size = 0.3                # a fraction of the window's width, 0.1 to 0.9
        # Built in: sessions on the left at 0.28, every other drawer on the right at 0.5.


        """

    private static func quoted(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The line of each `[[bind]]` header, in order — row N's is the Nth. A row written another
    /// way (an inline array) has no header, and its refusal then names no line.
    private static func bindHeaderLines(in text: String) -> [Int] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .filter { $0.element.trimmingCharacters(in: .whitespaces).hasPrefix("[[bind]]") }
            .map { $0.offset + 1 }
    }

    /// TOMLDecoder's own syntax errors carry the line (`(Line 3) …`), wrapped in a
    /// `DecodingError`; the wrapper's sentence says only that the data was not TOML.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case let DecodingError.dataCorrupted(context) where context.underlyingError != nil:
            return String(describing: context.underlyingError!)
        case let DecodingError.typeMismatch(_, context),
            let DecodingError.valueNotFound(_, context),
            let DecodingError.dataCorrupted(context):
            let key = context.codingPath.last.map { "\($0.stringValue): " } ?? ""
            return key + context.debugDescription
        case let DecodingError.keyNotFound(key, _):
            return "\(key.stringValue) is missing"
        default:
            return String(describing: error)
        }
    }

    fileprivate struct RowError: Error {
        let index: Int
        let reason: String
    }

    /// The file as TOML has it, before any name is checked.
    private struct RawFile: Decodable {
        let bind: [RawRow]
        let unbind: [String]
        let drawer: [String: RawDrawer]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: FieldKey.self)
            try FieldKey.refuseUnknown(
                container.allKeys, allowed: ["bind", "unbind", "drawer"], in: nil)
            unbind = try container.decodeIfPresent([String].self, forKey: "unbind") ?? []
            drawer =
                try container.decodeIfPresent([String: RawDrawer].self, forKey: "drawer") ?? [:]
            var rows: [RawRow] = []
            if container.contains("bind") {
                var list = try container.nestedUnkeyedContainer(forKey: "bind")
                while !list.isAtEnd {
                    let index = list.currentIndex
                    do {
                        rows.append(try list.decode(RawRow.self))
                    } catch let problem as KeymapProblem {
                        throw RowError(index: index, reason: problem.reason)
                    } catch {
                        throw RowError(index: index, reason: KeymapFile.describe(error))
                    }
                }
            }
            bind = rows
        }
    }
}

/// Why a keymap file was refused, as the status bar says it.
struct KeymapProblem: Error, Equatable {
    /// 1-based. nil when the reason is about the file as a whole, or the row has no header.
    let line: Int?
    let reason: String

    var sentence: String {
        "keymap.toml: " + (line.map { "line \($0): " } ?? "") + reason
    }
}

extension Error {
    fileprivate var reason: String { (self as? KeymapProblem)?.reason ?? "\(self)" }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - A row

/// One `[[bind]]` row as TOML has it.
private struct RawRow: Decodable {
    let key: String
    let when: String?
    let action: String
    let arguments: KeymapArguments
    let hint: String?
    let menu: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: FieldKey.self)
        try FieldKey.refuseUnknown(
            c.allKeys,
            allowed: ["key", "when", "action", "hint", "menu"] + KeymapArguments.fields,
            in: "[[bind]]")
        key = try c.decode(String.self, forKey: "key")
        when = try c.decodeIfPresent(String.self, forKey: "when")
        action = try c.decode(String.self, forKey: "action")
        arguments = KeymapArguments(
            direction: try c.decodeIfPresent(String.self, forKey: "direction"),
            index: try c.decodeIfPresent(Int.self, forKey: "index"),
            delta: try c.decodeIfPresent(Int.self, forKey: "delta"),
            step: try c.decodeIfPresent(String.self, forKey: "step"),
            offset: try c.decodeIfPresent(Int.self, forKey: "offset"),
            name: try c.decodeIfPresent(String.self, forKey: "name"),
            surface: try c.decodeIfPresent(String.self, forKey: "surface"),
            recipe: try c.decodeIfPresent(String.self, forKey: "recipe"))
        hint = try c.decodeIfPresent(String.self, forKey: "hint")
        menu = try c.decodeIfPresent(String.self, forKey: "menu")
    }

    func binding() throws(KeymapProblem) -> KeyBinding {
        let chord = try KeyChord(parsing: key)
        let when = try when.map(KeyBinding.When.init(parsing:)) ?? .anywhere
        let action = try KeyBinding.Action(name: action, arguments: arguments)
        return KeyBinding(
            chord.trigger, chord.modifiers, action, when: when, hint: hint, menu: menu)
    }
}

/// One `[drawer.<name>]` table as TOML has it.
private struct RawDrawer: Decodable {
    let edge: String?
    let size: Double?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: FieldKey.self)
        let name = decoder.codingPath.last?.stringValue ?? "<name>"
        try FieldKey.refuseUnknown(c.allKeys, allowed: ["edge", "size"], in: "[drawer.\(name)]")
        edge = try c.decodeIfPresent(String.self, forKey: "edge")
        size = try c.decodeIfPresent(Double.self, forKey: "size")
    }

    /// The drawer's built-in style with whatever the table sets.
    func style(for name: String) throws(KeymapProblem) -> DrawerStyle {
        var style = DrawerStyle.builtIn(for: name)
        if let edge {
            guard let parsed = DrawerStyle.Edge(rawValue: edge) else {
                throw KeymapProblem(line: nil, reason: "edge is left or right, not '\(edge)'")
            }
            style.edge = parsed
        }
        if let size {
            guard DrawerStyle.sizes.contains(size) else {
                throw KeymapProblem(line: nil, reason: "size is 0.1 to 0.9, not \(size)")
            }
            style.size = size
        }
        return style
    }
}

private struct FieldKey: CodingKey, ExpressibleByStringLiteral {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(stringLiteral value: String) { stringValue = value }

    static func refuseUnknown(_ keys: [FieldKey], allowed: [String], in table: String?) throws {
        if let unknown = keys.map(\.stringValue).sorted().first(where: { !allowed.contains($0) }) {
            throw KeymapProblem(
                line: nil,
                reason: "unknown field '\(unknown)'" + (table.map { " in \($0)" } ?? ""))
        }
    }
}

// MARK: - A chord

/// A key and its modifiers, as the file spells them: `cmd+shift+b`, `ctrl+left`, `cmd+plus`.
///
/// One name per thing: `cmd`, `ctrl`, `alt`, `shift`; `plus` for the `+` key, because `+` joins
/// the parts; `left`/`right`/`up`/`down` for the arrows; `keycode:N` for any other key code.
struct KeyChord: Equatable {
    let trigger: KeyBinding.Trigger
    let modifiers: NSEvent.ModifierFlags

    init(_ trigger: KeyBinding.Trigger, _ modifiers: NSEvent.ModifierFlags) {
        self.trigger = trigger
        self.modifiers = modifiers
    }

    private static let modifierNames: [(String, NSEvent.ModifierFlags)] = [
        ("cmd", .command), ("ctrl", .control), ("alt", .option), ("shift", .shift),
    ]

    init(parsing text: String) throws(KeymapProblem) {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, !parts.contains(where: \.isEmpty) else {
            throw KeymapProblem(line: nil, reason: "key '\(text)': write the + key as 'plus'")
        }
        var modifiers: NSEvent.ModifierFlags = []
        for name in parts.dropLast() {
            guard let flag = Self.modifierNames.first(where: { $0.0 == name })?.1 else {
                throw KeymapProblem(
                    line: nil, reason: "key '\(text)': '\(name)' is not cmd, ctrl, alt or shift")
            }
            guard !modifiers.contains(flag) else {
                throw KeymapProblem(line: nil, reason: "key '\(text)': '\(name)' twice")
            }
            modifiers.insert(flag)
        }
        self.init(try Self.trigger(key, in: text), modifiers)
    }

    private static func trigger(
        _ key: String, in text: String
    ) throws(KeymapProblem)
        -> KeyBinding.Trigger
    {
        if key == "plus" { return .character("+") }
        if let arrow = ArrowKey.allCases.first(where: { $0.name == key }) { return arrow.trigger }
        if key.hasPrefix("keycode:") {
            guard let code = UInt16(key.dropFirst("keycode:".count)), code < 128 else {
                throw KeymapProblem(
                    line: nil, reason: "key '\(text)': a key code is a number from 0 to 127")
            }
            return .keyCode(code)
        }
        guard key.count == 1, key != " " else {
            throw KeymapProblem(
                line: nil,
                reason: "key '\(text)': '\(key)' is not one character, plus, an arrow or "
                    + "keycode:N")
        }
        return .character(key.lowercased())
    }

    var spelled: String {
        let key: String =
            switch trigger {
            case .character("+"): "plus"
            case let .character(character): character
            case let .keyCode(code): ArrowKey(trigger)?.name ?? "keycode:\(code)"
            }
        let names = Self.modifierNames.filter { modifiers.contains($0.1) }.map(\.0)
        return (names + [key]).joined(separator: "+")
    }
}

extension KeyBinding {
    var chord: KeyChord { KeyChord(trigger, modifiers) }

    /// Whether one keystroke could fire both rows — the first would win and the second would be
    /// unreachable.
    func collides(with other: KeyBinding) -> Bool {
        chord == other.chord && when.overlaps(other.when)
    }
}

extension KeyBinding.When {
    /// Two `when`s overlap unless they are the two opposite halves; `anywhere` overlaps both.
    func overlaps(_ other: Self) -> Bool {
        self == other || self == .anywhere || other == .anywhere
    }

    var spelled: String {
        switch self {
        case .anywhere: "anywhere"
        case .terminalFocused: "terminal"
        case .awayFromTerminal: "away-from-terminal"
        }
    }

    init(parsing text: String) throws(KeymapProblem) {
        switch text {
        case "anywhere": self = .anywhere
        case "terminal": self = .terminalFocused
        case "away-from-terminal": self = .awayFromTerminal
        default:
            throw KeymapProblem(
                line: nil,
                reason: "when '\(text)' is not anywhere, terminal or away-from-terminal")
        }
    }
}
