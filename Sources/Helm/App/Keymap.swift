import AppKit

/// Installs helm's key handling as a local `NSEvent` monitor.
///
/// A monitor rather than menu shortcuts alone, because the terminal claims
/// command-key equivalents before the menu ever sees them — standalone ghostty binds
/// ⌘T to new-tab, and embedded it swallows all of them. A local monitor runs before
/// any view's key handling, so helm's bindings always win; consumed events (returning
/// nil) never reach the pty.
///
/// All this does is ask `Shortcut.match` and post. The map itself is data, so the
/// decisions live in `Shortcut` where they can be tested.
enum Keymap {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // The monitor runs on the main thread, so assumeIsolated is safe.
            let terminalFocused = MainActor.assumeIsolated {
                TerminalManager.shared.anyTerminalHasFocus
            }
            guard
                let shortcut = Shortcut.match(
                    characters: event.charactersIgnoringModifiers,
                    keyCode: event.keyCode,
                    modifiers: modifiers,
                    terminalFocused: terminalFocused
                )
            else { return event }
            NotificationCenter.default.post(name: shortcut.notification, object: shortcut.object)
            return nil
        }
    }
}
