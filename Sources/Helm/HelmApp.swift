import AppKit
import SwiftUI

@main
struct HelmApp: App {
    init() {
        // Running as a bare SPM executable (`swift run helm`) — without this the process
        // stays a background app and the window never fronts. Removed once helm becomes
        // a real .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
