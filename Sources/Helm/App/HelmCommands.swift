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
                // `Shortcut.post()` pairs the notification with its object — see that
                // method for why this file must not assemble one itself (#152).
                Button(menu.title) { shortcut.post() }
                    .keyboardShortcut(menu.key, modifiers: menu.modifiers)
            }
        }
    }
}
