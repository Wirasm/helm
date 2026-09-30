import SwiftUI

/// The keys available right now, shown while the manage key is held (#499).
///
/// **Read from the table in force, never written down.** Both columns are `KeyHints` over
/// `Keymap.table`, so a row the operator adds, rebinds or unbinds in `keymap.toml` shows up
/// here the moment the file reloads, and a key that cannot fire where the keyboard is (⌃1–9 in
/// a terminal) is not offered. The same rows the monitor matches, the same hints the status bar
/// used to show: one table, no second list to drift.
enum KeyPopupContent {
    struct Sections: Equatable {
        /// The manage layer, written without the manage key he is already holding: `HJKL`,
        /// `⇧HJKL`, `1–9`.
        let held: [KeyHint]
        /// Everything else he can press here, with its full chord. A word the layer already
        /// says is not said again: ⌃1–9 switches workspace too, but he is holding ⌥⌘ and 1–9 is
        /// right there.
        let other: [KeyHint]
    }

    static func of(
        _ table: [KeyBinding], manage: ManageKey, focus: KeyFocus
    ) -> Sections {
        let layer = table.filter { manage.holds($0.modifiers) }.map { row in
            KeyBinding(
                row.trigger, row.modifiers.subtracting(manage.modifiers), row.action,
                when: row.when, hint: row.hint, menu: row.menu)
        }
        let held = KeyHints.visible(focus: focus, in: layer)
        let other = KeyHints.visible(
            focus: focus, in: table.filter { !manage.holds($0.modifiers) })
        return Sections(
            held: held, other: other.filter { hint in !held.contains { $0.label == hint.label } })
    }
}

/// The pop-up itself: a panel along the bottom of the bench, over it and never in it, and deaf
/// to clicks so it can never land a click somewhere other than where the operator aimed.
struct KeyPopup: View {
    @ObservedObject var keymap: Keymap
    @ObservedObject var hold: ManageHold
    /// Which keys can fire depends on what holds the keyboard.
    @StateObject private var focus = KeyFocusWatch()

    var body: some View {
        ZStack(alignment: .bottom) {
            if hold.isShowing {
                panel
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.1), value: hold.isShowing)
    }

    private var panel: some View {
        KeyPopupPanel(
            manage: keymap.manage,
            sections: KeyPopupContent.of(
                keymap.table, manage: keymap.manage, focus: focus.focus))
    }
}

/// The panel, drawn from values: the manage key he is holding and the two columns of hints.
struct KeyPopupPanel: View {
    let manage: ManageKey
    let sections: KeyPopupContent.Sections

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            column("holding \(KeyGlyph.modifiers(manage.modifiers))", sections.held)
            Color.border.frame(width: 1)
            column("other keys", sections.other)
        }
        .fixedSize()
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.border))
        .shadow(color: .black.opacity(0.3), radius: 12)
    }

    private func column(_ title: String, _ hints: [KeyHint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.textFaint)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(hints) { hint in
                    GridRow {
                        Text(hint.keys)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Color.textPrimary)
                            .gridColumnAlignment(.trailing)
                        Text(hint.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textMuted)
                    }
                }
            }
        }
    }
}
