import AppKit

/// One thing the status bar says you can press.
///
/// `keys` is **rendered from `Shortcut.all`**, never typed. That is the whole design
/// constraint of this file: helm binds a few dozen keys and nothing in the window mentioned
/// any of them, so the operator could not open a second pane without reading source — but a
/// hand-written list of glyphs would be a second copy of the keymap, and the second copy is
/// always the one that goes stale. Only the *word* for a command is written here, and a
/// word cannot be wrong about which key fires.
struct KeyHint: Equatable, Identifiable {
    /// "⌘⌥1–9", "⌘↑↓", "⌘N" — glyphs, from the map.
    let keys: String
    /// The word the operator would use, lowercase because chrome recedes.
    let label: String

    var id: String { label }
}

/// The commands the bar names, in reading order.
///
/// **Curation, and nothing else.** Which commands are worth a hint is a design judgement
/// and it is made here, in the open; what each one is BOUND to is not decided here at all.
/// `KeyHintCatalogTests` requires that `named` and `omitted` together account for every
/// notification in `Shortcut.all`, so a new shortcut cannot slip in unadvertised and an
/// advertised one cannot outlive its binding — the compiler will not catch either, and the
/// test does.
enum KeyHintCatalog {
    /// Ordered: the pane commands first, because they are the ones an operator needs on day
    /// one and the ones nothing else in the window hints at.
    static let named: [(command: Notification.Name, label: String)] = [
        (.helmNewTerminal, "new"),
        (.helmSplitRight, "split"),
        (.helmSplitDown, "split down"),
        (.helmClosePane, "close"),
        (.helmSelectTerminal, "pane"),
        (.helmMoveFocus, "focus"),
        (.helmToggleChat, "chat"),
        (.helmOpenArtifact, "artifact"),
        (.helmOpenCanvasURL, "url"),
        (.helmJumpToPrompt, "turn"),
        (.helmSelectWorkspace, "workspace"),
        (.helmCycleWorkspace, "cycle"),
        (.helmOpenWorkspace, "folder"),
        (.helmToggleRail, "archon"),
    ]

    /// Left off the bar on purpose.
    ///
    /// Font size is bound five ways — ⌘=, ⌘+, ⌘⇧+, ⌘-, ⌘0 — because of how the shift key
    /// reaches `charactersIgnoringModifiers`, and rendering that honestly would spend a
    /// tenth of the bar on the one command every macOS app binds identically. It keeps its
    /// menu items, which is where a universal shortcut belongs.
    static let omitted: Set<Notification.Name> = [.helmAdjustFontSize]
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
    /// `shortcuts` is a parameter rather than a read of `Shortcut.all` so the rules are
    /// exercisable against a two-row map instead of the real one.
    static func visible(
        terminalFocused: Bool, in shortcuts: [Shortcut] = Shortcut.all
    ) -> [KeyHint] {
        KeyHintCatalog.named.compactMap { command, label in
            let live = shortcuts.filter {
                $0.notification == command && $0.canFire(terminalFocused: terminalFocused)
            }
            // The FIRST binding that can fire, not all of them. `Shortcut.all` is in match
            // order, so the first is the one the operator's keystroke would actually hit.
            guard let first = live.first,
                let keys = render(live.filter { $0.modifiers == first.modifiers })
            else { return nil }
            return KeyHint(keys: keys, label: label)
        }
    }

    /// One binding's rows — same command, same modifiers — as a single string.
    ///
    /// Collapsing is not decoration: nine rows for ⌘1…⌘9 rendered one by one would be the
    /// whole bar, and the two runs helm binds (digits, arrows) are exactly the two a human
    /// reads as one thing anyway.
    private static func render(_ rows: [Shortcut]) -> String? {
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
    static func trigger(_ trigger: Shortcut.Trigger) -> String? {
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
