import AppKit

/// Installs helm's key handling as a local `NSEvent` monitor.
///
/// A monitor rather than menu shortcuts alone, because the terminal claims command-key
/// equivalents before the menu ever sees them — standalone ghostty binds ⌘T to new-tab, and
/// embedded it swallows all of them. A local monitor runs before any view's key handling, so
/// helm's bindings always win; consumed events (returning nil) never reach the pty.
///
/// All this does is ask `KeyBindings.match` against the table in force (`Keymap`) and hand the
/// row's action to `Actions`. The table is data, so the decisions live there, where they can be
/// tested. It also tells `ManageHold` when the modifiers change, a key goes down or helm stops
/// being active, which is everything the key pop-up turns on (#499).
enum KeymapMonitor {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            MainActor.assumeIsolated {
                ManageHold.shared.receive(
                    .modifiers(held: Keymap.shared.manage.holds(modifiers)))
            }
            return event
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ManageHold.shared.receive(.resign) }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers
            let keyCode = event.keyCode
            // The monitor runs on the main thread, so assumeIsolated is safe.
            let consumed = MainActor.assumeIsolated {
                ManageHold.shared.receive(.key)
                guard
                    let row = KeyBindings.match(
                        characters: characters, keyCode: keyCode, modifiers: modifiers,
                        terminalFocused: TerminalManager.shared.anyTerminalHasFocus,
                        in: Keymap.shared.table)
                else { return false }
                Actions.perform(row.action)
                return true
            }
            return consumed ? nil : event
        }
    }
}
