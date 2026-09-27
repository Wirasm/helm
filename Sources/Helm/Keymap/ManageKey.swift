import AppKit

/// The modifier the bench's own keys ride on (#498): hold it and h/j/k/l move focus, ⇧ + those
/// move the pane, 1–9 switch workspace, W closes. Release it and the keyboard types again.
///
/// **The layer is a property of a modifier set, not a kind of row.** A row whose modifiers are
/// exactly this set, or this set plus ⇧, is in the manage layer. A native app gets the chord with
/// its modifiers, so "while ⌘⌥ is held, H steps focus" *is* the chord ⌘⌥H, and `Keymap.table`
/// keeps concrete modifiers: the monitor, the menu and the status bar never learn the word.
///
/// **⌘⌥ by default**, because that is the family helm already bound (focus, move, workspace,
/// close), and because of what the other modifiers do in a terminal: ⌥ types characters on many
/// layouts (Swedish puts `| [ ] { } @ $ \` there), ⌃ sends control codes (⌃H is backspace), and
/// ⌘ alone is ⌘1–9, ⌘N, ⌘D. `manage = "cmd+ctrl"` in the keymap file moves the whole family.
struct ManageKey: Equatable {
    let modifiers: NSEvent.ModifierFlags

    static let builtIn = ManageKey(unchecked: [.command, .option])

    private init(unchecked modifiers: NSEvent.ModifierFlags) {
        self.modifiers = modifiers
    }

    /// `cmd+alt`, `cmd+ctrl`: the names a chord uses, with no key.
    ///
    /// **It must include ⌘**, so it can never take a keystroke a terminal needs as input, and it
    /// **cannot include ⇧**, which is the layer's own second meaning (move rather than focus).
    init(parsing text: String) throws(KeymapProblem) {
        var modifiers: NSEvent.ModifierFlags = []
        for name in text.split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
            guard let flag = KeyChord.modifier(named: name) else {
                throw KeymapProblem(
                    line: nil, reason: "manage '\(text)': '\(name)' is not cmd, ctrl or alt")
            }
            guard !modifiers.contains(flag) else {
                throw KeymapProblem(line: nil, reason: "manage '\(text)': '\(name)' twice")
            }
            modifiers.insert(flag)
        }
        guard modifiers.contains(.command) else {
            throw KeymapProblem(
                line: nil,
                reason: "manage '\(text)' must include cmd, so it never takes a key a "
                    + "terminal types")
        }
        guard !modifiers.contains(.shift) else {
            throw KeymapProblem(
                line: nil,
                reason: "manage '\(text)' cannot include shift: shift is the manage layer's "
                    + "second meaning")
        }
        self.init(unchecked: modifiers)
    }

    /// Whether a chord with `modifiers` is in the layer: this set, with or without ⇧. The one
    /// definition, read by rebasing, by the file's spelling and by the key pop-up.
    func holds(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.subtracting(.shift) == self.modifiers
    }

    /// `row` moved from `old`'s layer onto this one, keeping its ⇧. A row outside `old`'s layer
    /// is returned as it is.
    func rebase(_ row: KeyBinding, from old: ManageKey) -> KeyBinding {
        guard self != old, old.holds(row.modifiers) else { return row }
        return KeyBinding(
            row.trigger, modifiers.union(row.modifiers.intersection(.shift)), row.action,
            when: row.when, hint: row.hint, menu: row.menu)
    }

    var spelled: String { KeyChord.names(of: modifiers).joined(separator: "+") }
}
