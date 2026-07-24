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
        // Helm's shortcuts must work while the ghostty view is first responder, but
        // the terminal claims command-key equivalents before the menu sees them
        // (standalone ghostty binds ⌘T to new-tab; embedded, it swallows all of
        // them). A local monitor runs before any view's key handling, so these
        // always win; consumed keys (return nil) never reach the pty.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let key = event.charactersIgnoringModifiers
            else { return event }
            switch key {
            // ⌘T — toggle the two faces (terminal workspace ⇄ kild view).
            case "t":
                NotificationCenter.default.post(name: .helmToggleView, object: nil)
                return nil
            // ⌘N — new terminal tab (a fresh login shell).
            case "n":
                NotificationCenter.default.post(name: .helmNewTerminal, object: nil)
                return nil
            // ⌘O — open an artifact file beside the terminal.
            case "o":
                NotificationCenter.default.post(name: .helmOpenArtifact, object: nil)
                return nil
            // ⌘1–⌘9 — select terminal by tab position (1-based keys, 0-based index).
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                NotificationCenter.default.post(
                    name: .helmSelectTerminal,
                    object: Int(key)! - 1
                )
                return nil
            default:
                return event
            }
        }
    }

    var body: some Scene {
        WindowGroup("helm") {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                // Menu mirrors of the monitor's shortcuts (the monitor consumes the
                // keystrokes first; these exist for discoverability and mouse use).
                ToggleViewCommand()
                Button("New Terminal") {
                    NotificationCenter.default.post(name: .helmNewTerminal, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Artifact…") {
                    NotificationCenter.default.post(name: .helmOpenArtifact, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
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
    /// ⌘T — swap RootView's frontmost face (terminal workspace ⇄ kild view).
    static let helmToggleView = Notification.Name("helmToggleView")
    /// ⌘N — TerminalManager appends and selects a fresh login shell.
    static let helmNewTerminal = Notification.Name("helmNewTerminal")
    /// ⌘1–⌘9 — object is the 0-based tab index to select.
    static let helmSelectTerminal = Notification.Name("helmSelectTerminal")
    /// ⌘O — the artifact pane presents its open panel.
    static let helmOpenArtifact = Notification.Name("helmOpenArtifact")
}
