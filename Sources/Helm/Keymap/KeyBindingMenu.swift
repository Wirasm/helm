import SwiftUI

/// The menu-bar mirror of the key table: one item per row that has a `menu`.
///
/// Built from the effective table (`Keymap`) rather than restated, so an item cannot drift from
/// the key it mirrors, and a reloaded keymap file changes the menu with the keys. The monitor
/// consumes the keystrokes first; these items exist for discoverability and for the mouse, and
/// they fire the row's own action — the one route #152 needed.
struct KeyBindingMenu: View {
    @ObservedObject var keymap: Keymap

    var body: some View {
        ForEach(Array(keymap.table.enumerated()), id: \.offset) { _, row in
            if let title = row.menu {
                Button(title) { Actions.perform(row.action) }
                    .keyboardShortcut(row.menuShortcut)
            }
        }
    }
}
