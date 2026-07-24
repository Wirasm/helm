import AppKit
import SwiftUI

@main
struct HelmApp: App {
    init() {
        // Running as a bare SPM executable (`swift run helm`) the process has no
        // Info.plist, so AppKit treats it as a background app and the window never
        // fronts — force it regular and activate. Inside the real .app bundle
        // (`make app`) Bundle.main has an identifier, Launch Services handles
        // activation natively, and forcing it here would steal focus — skip it.
        if Bundle.main.bundleIdentifier == nil {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        // ⌘T must work while the ghostty view is first responder, but the terminal
        // claims command-key equivalents before the menu sees them (standalone ghostty
        // binds ⌘T to new-tab; embedded, it swallows it). A local monitor runs before
        // any view's key handling, so the toggle always wins.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "t" {
                NotificationCenter.default.post(name: .helmToggleView, object: nil)
                return nil
            }
            return event
        }
    }

    var body: some Scene {
        WindowGroup("helm") {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                // ⌘T toggles the two faces of helm: the terminal (your driver lives
                // here) and the kild view (rooms, decisions, artifacts).
                ToggleViewCommand()
            }
        }
    }
}

/// The main-view toggle, exposed as a menu command so ⌘T works app-wide.
struct ToggleViewCommand: View {
    var body: some View {
        Button("Toggle Terminal / Kild View") {
            NotificationCenter.default.post(name: .helmToggleView, object: nil)
        }
        .keyboardShortcut("t", modifiers: .command)
    }
}

extension Notification.Name {
    static let helmToggleView = Notification.Name("helmToggleView")
}
