import SwiftUI

/// The menu-bar mirror of the key table: one item per row that has a `menu`.
///
/// Built from `KeyBindings.all` rather than restated, so an item cannot drift from the key it
/// mirrors. The monitor consumes the keystrokes first; these items exist for discoverability
/// and for the mouse, and they fire the row's own action — the one route #152 needed.
struct KeyBindingMenu: View {
    var body: some View {
        ForEach(Array(KeyBindings.all.enumerated()), id: \.offset) { _, row in
            if let menu = row.menu {
                Button(menu.title) { Actions.perform(row.action) }
                    .keyboardShortcut(menu.key, modifiers: menu.modifiers)
            }
        }
    }
}
