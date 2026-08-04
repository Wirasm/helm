import SwiftUI

/// The menu-bar mirror of the keyboard map.
///
/// Built from `Shortcut.all` rather than restated, so a row cannot drift from the
/// binding it mirrors — the duplication this replaces was nine shortcuts written
/// once in the monitor and again here. The monitor consumes the keystrokes first;
/// these entries exist for discoverability and mouse use.
struct HelmCommands: View {
    var body: some View {
        ForEach(Array(Shortcut.all.enumerated()), id: \.offset) { _, shortcut in
            if let menu = shortcut.menu {
                // `Shortcut.post()`, not a notification assembled here. This file used to pair
                // the name with the raw `payload`, which is nil on all four focus-movement
                // rows — so View ▸ Focus Left/Right/Up/Down posted nothing the subscriber
                // would accept and were silent no-ops from the day this file was split out of
                // the god module (#152). Pairing happens once, in the table.
                Button(menu.title) { shortcut.post() }
                    .keyboardShortcut(menu.key, modifiers: menu.modifiers)
            }
        }
    }
}
