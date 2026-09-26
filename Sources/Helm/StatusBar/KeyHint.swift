import AppKit

/// One thing the status bar says you can press.
///
/// Both halves come from the key table in force (`Keymap.table`): `keys` is **rendered** from the rows,
/// never typed, and `label` is the row's own `hint`. helm binds a few dozen keys and nothing in
/// the window mentioned any of them, so the operator could not open a second pane without
/// reading source — but a hand-written list of glyphs would be a second copy of the keymap, and
/// the second copy is always the one that goes stale. That is why the word lives on the row:
/// the table used to be answered by a separate catalogue of labels, and a test had to keep the
/// two in step.
///
/// Rows without a `hint` stay off the bar on purpose. Font size is bound five ways — ⌘=, ⌘+,
/// ⌘⇧+, ⌘-, ⌘0 — because of how shift reaches `charactersIgnoringModifiers`, and rendering
/// that honestly would spend a tenth of the bar on the one command every macOS app binds
/// identically. It keeps its menu items, which is where a universal shortcut belongs.
struct KeyHint: Equatable, Identifiable {
    /// "⌘⌥1–9", "⌘↑↓", "⌘N" — glyphs, from the table.
    let keys: String
    /// The word the operator would use, lowercase because chrome recedes.
    let label: String

    var id: String { label }
}

/// The hints to show, given where focus is.
enum KeyHints {
    /// **Focus-aware because the map genuinely is.** ⌃1–9 selects a workspace only while
    /// focus is away from the terminal — inside one those are the shell's own control codes
    /// — and ⌘⌥1–9 is the fallback that always works. A single fixed list would have to
    /// advertise one of them and be wrong half the time, so this asks each row whether it
    /// can fire and shows the first binding that can. The same rule silently drops ⌘↑↓,
    /// which only exists inside a terminal, and ⌃←→, which only exists outside one.
    ///
    /// In the order each label first appears in the table.
    ///
    /// `rows` is the table in force, passed rather than read so the rules are exercisable
    /// against a two-row table instead of the real one.
    static func visible(terminalFocused: Bool, in rows: [KeyBinding]) -> [KeyHint] {
        var labels: [String] = []
        for label in rows.compactMap(\.hint) where !labels.contains(label) {
            labels.append(label)
        }
        return labels.compactMap { label in
            let live = rows.filter {
                $0.hint == label && $0.canFire(terminalFocused: terminalFocused)
            }
            // The FIRST row that can fire, and the rows sharing its modifiers — the binding the
            // operator's keystroke would actually hit, not every way to reach the same word.
            guard let first = live.first,
                let keys = render(live.filter { $0.modifiers == first.modifiers })
            else { return nil }
            return KeyHint(keys: keys, label: label)
        }
    }

    /// One hint's rows — same label, same modifiers — as a single string.
    ///
    /// Collapsing is not decoration: nine rows for ⌘1…⌘9 rendered one by one would be the
    /// whole bar, and the two runs helm binds (digits, arrows) are exactly the two a human
    /// reads as one thing anyway.
    private static func render(_ rows: [KeyBinding]) -> String? {
        guard let modifiers = rows.first?.modifiers else { return nil }
        let glyphs = rows.compactMap { KeyGlyph.trigger($0.trigger) }
        guard !glyphs.isEmpty else { return nil }
        let prefix = KeyGlyph.modifiers(modifiers)
        if let run = digitRun(glyphs) { return prefix + run }
        if let arrows = arrows(glyphs) { return prefix + arrows }
        return glyphs.map { prefix + $0 }.joined(separator: " ")
    }

    /// "1–9" for a consecutive run of at least three digits, else nil. Two is not a run —
    /// "⌘1 ⌘2" is shorter than the dash form and says more.
    private static func digitRun(_ glyphs: [String]) -> String? {
        let digits = glyphs.compactMap { Int($0) }
        guard digits.count == glyphs.count, digits.count >= 3 else { return nil }
        guard zip(digits, digits.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else { return nil }
        return "\(digits[0])–\(digits[digits.count - 1])"
    }

    /// Arrow rows as one cluster in a fixed reading order, so ⌘⌥ + four arrows is "↑↓←→"
    /// however the map happens to list them. nil unless every glyph is an arrow.
    private static func arrows(_ glyphs: [String]) -> String? {
        let order = ["↑", "↓", "←", "→"]
        guard glyphs.allSatisfy(order.contains), glyphs.count >= 2 else { return nil }
        return order.filter(glyphs.contains).joined()
    }
}

/// A key event's shape, as the glyphs a menu would print.
enum KeyGlyph {
    /// One command's binding, as the glyphs a menu would print — "⇧⌘O".
    ///
    /// **Because typing them by hand goes wrong, and did.** The empty bench said `⌘⇧O` while
    /// the status bar said `⇧⌘O`, two places in one window disagreeing about one key (#149);
    /// the second is right, because macOS prints modifiers in the fixed order ⌃⌥⇧⌘ and the
    /// operator's eye already parses that. Any surface outside the status bar that wants to
    /// name a key asks here instead, on `KeyHint`'s own reasoning: a hand-written glyph is a
    /// second copy of the keymap, and the second copy is the one that goes stale.
    ///
    /// The first row that binds the action, which for an action bound once is the only one.
    /// nil when nothing binds it or its trigger has no glyph.
    static func binding(for action: KeyBinding.Action, in rows: [KeyBinding]) -> String? {
        guard let row = rows.first(where: { $0.action == action }),
            let key = trigger(row.trigger)
        else { return nil }
        return modifiers(row.modifiers) + key
    }

    /// macOS's canonical modifier order — ⌃⌥⇧⌘ — which is what a menu bar prints and
    /// therefore what the operator's eye already parses.
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }
            .map(\.1)
            .joined()
    }

    /// The key itself, or nil for a keyCode helm does not draw. Arrow keys are matched on
    /// their code rather than a character (they carry function-key code points, not typable
    /// ones), so they are the only codes that need naming here.
    static func trigger(_ trigger: KeyBinding.Trigger) -> String? {
        switch trigger {
        case let .character(character): character.uppercased()
        case let .keyCode(code):
            switch code {
            case 123: "←"
            case 124: "→"
            case 125: "↓"
            case 126: "↑"
            default: nil
            }
        }
    }
}
