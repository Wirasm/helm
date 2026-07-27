import AppKit
import SwiftUI

/// App-level appearance override: System follows macOS, Light/Dark pin the
/// app. Applied via `NSApp.appearance` (nil = System), which every window —
/// and the `colorScheme` environment the mermaid islands re-theme on —
/// inherits. Persisted under `HelmApp.appearanceKey`; the View ▸ Appearance
/// menu and the terminal strip's affordance share that storage.
enum AppearanceOverride: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The NSAppearance name to force, or nil to follow the system.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = appearanceName.flatMap { NSAppearance(named: $0) }
    }
}

@main
struct HelmApp: App {
    /// The one @AppStorage key for the appearance override (raw
    /// `AppearanceOverride` value; unknown values fall back to system).
    static let appearanceKey = "helmAppearance"

    @AppStorage(HelmApp.appearanceKey)
    private var appearanceRaw = AppearanceOverride.system.rawValue

    private var appearance: AppearanceOverride {
        AppearanceOverride(rawValue: appearanceRaw) ?? .system
    }

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
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌘↑/⌘↓ — jump between shell prompts (matched on keyCode: arrows
            // carry function-key code points, not typable characters). Consumed
            // only while the terminal itself holds keyboard focus: the frame
            // now keeps sidebar + dock text fields alongside the always-visible
            // terminal, and ⌘↑/↓ must keep its text-navigation meaning there.
            // (The monitor runs on the main thread; assumeIsolated is safe.)
            if flags == .command, event.keyCode == 126 || event.keyCode == 125 {
                let terminalFocused = MainActor.assumeIsolated {
                    TerminalManager.shared.selectedTerminalHasFocus
                }
                if terminalFocused {
                    NotificationCenter.default.post(
                        name: .helmJumpToPrompt, object: event.keyCode == 126 ? -1 : 1
                    )
                    return nil
                }
            }
            guard let key = event.charactersIgnoringModifiers else { return event }
            // ⌘⇧= is how ⌘+ is actually typed (charactersIgnoringModifiers
            // keeps shift applied); everything else requires bare ⌘.
            if flags == [.command, .shift], key == "+" {
                NotificationCenter.default.post(
                    name: .helmAdjustFontSize, object: FontSizeStep.increase.rawValue
                )
                return nil
            }
            // ⌘⇧O — open a folder as a workspace (⌘O is the artifact browser).
            // Shift keeps the letter uppercase in charactersIgnoringModifiers.
            if flags == [.command, .shift], key.lowercased() == "o" {
                NotificationCenter.default.post(name: .helmOpenWorkspace, object: nil)
                return nil
            }
            guard flags == .command else { return event }
            switch key {
            // ⌘+/⌘-/⌘0 — per-terminal font zoom on the selected terminal.
            case "=", "+":
                NotificationCenter.default.post(
                    name: .helmAdjustFontSize, object: FontSizeStep.increase.rawValue
                )
                return nil
            case "-":
                NotificationCenter.default.post(
                    name: .helmAdjustFontSize, object: FontSizeStep.decrease.rawValue
                )
                return nil
            case "0":
                NotificationCenter.default.post(
                    name: .helmAdjustFontSize, object: FontSizeStep.reset.rawValue
                )
                return nil
            // ⌘T is deliberately UNBOUND — it was the two-faces toggle, freed
            // when the one-surface re-layout killed that model (slice 1a).
            // Reserved: rebind it only with intent, muscle memory lives here.
            //
            // ⌘J is also reserved, not bound: the future terminal-maximize
            // ("driver mode" in the concept — the terminal swells full-frame).
            //
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
                // The override is applied at the AppKit level so it also
                // reaches sheets and any future windows; re-applied whenever
                // the stored value changes (menu or strip affordance).
                .onAppear { appearance.apply() }
                .onChange(of: appearanceRaw) { appearance.apply() }
        }
        .commands {
            // View ▸ Appearance — the discoverable, menu-bar home of the
            // override (the terminal strip carries the in-window affordance).
            CommandGroup(after: .sidebar) {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppearanceOverride.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            CommandGroup(after: .toolbar) {
                // Menu mirrors of the monitor's shortcuts (the monitor consumes the
                // keystrokes first; these exist for discoverability and mouse use).
                Button("New Terminal") {
                    NotificationCenter.default.post(name: .helmNewTerminal, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Artifact…") {
                    NotificationCenter.default.post(name: .helmOpenArtifact, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Open Workspace…") {
                    NotificationCenter.default.post(name: .helmOpenWorkspace, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Increase Font Size") {
                    NotificationCenter.default.post(
                        name: .helmAdjustFontSize, object: FontSizeStep.increase.rawValue
                    )
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Font Size") {
                    NotificationCenter.default.post(
                        name: .helmAdjustFontSize, object: FontSizeStep.decrease.rawValue
                    )
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") {
                    NotificationCenter.default.post(
                        name: .helmAdjustFontSize, object: FontSizeStep.reset.rawValue
                    )
                }
                .keyboardShortcut("0", modifiers: .command)
                Divider()
                // ⌘↑/⌘↓ — scroll between shell-integration prompt marks
                // (OSC 133). In an agent session each turn leaves a mark, so
                // this is effectively jump-between-turns.
                Button("Jump to Previous Prompt") {
                    NotificationCenter.default.post(name: .helmJumpToPrompt, object: -1)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Jump to Next Prompt") {
                    NotificationCenter.default.post(name: .helmJumpToPrompt, object: 1)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    /// ⌘N — TerminalManager appends and selects a fresh login shell.
    static let helmNewTerminal = Notification.Name("helmNewTerminal")
    /// ⌘1–⌘9 — object is the 0-based tab index to select.
    static let helmSelectTerminal = Notification.Name("helmSelectTerminal")
    /// ⌘O — the artifact pane presents its open panel.
    static let helmOpenArtifact = Notification.Name("helmOpenArtifact")
    /// ⌘⇧O — the sidebar presents the folder picker; the chosen folder becomes an
    /// open workspace. No payload: the panel runs at the receiver.
    static let helmOpenWorkspace = Notification.Name("helmOpenWorkspace")
    /// ⌘+/⌘-/⌘0 — object is a `FontSizeStep` raw value; the terminal
    /// workspace applies it to the selected terminal.
    static let helmAdjustFontSize = Notification.Name("helmAdjustFontSize")
    /// ⌘↑/⌘↓ — object is the prompt offset (-1 previous, +1 next); the
    /// terminal workspace forwards it to the selected terminal's surface.
    static let helmJumpToPrompt = Notification.Name("helmJumpToPrompt")
}
