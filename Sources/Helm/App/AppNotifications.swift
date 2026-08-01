import Foundation

/// Every app-level command helm posts. A vertical listens for the ones it owns;
/// `Shortcut` maps keys onto them and `HelmCommands` puts the mirrored ones in the menu.
extension Notification.Name {
    /// ⌘N — TerminalManager appends and selects a fresh login shell.
    static let helmNewTerminal = Notification.Name("helmNewTerminal")
    /// ⌘1–⌘9 — object is the 0-based tab index to select.
    static let helmSelectTerminal = Notification.Name("helmSelectTerminal")
    /// ⌘O — the artifact pane presents its open panel.
    static let helmOpenArtifact = Notification.Name("helmOpenArtifact")
    /// A ⌘-click on an OSC 8 link the agent printed — object is the `file:` URL to
    /// render in the artifact pane. Distinct from `helmOpenArtifact`, which is the
    /// payload-less ⌘O that summons the picker.
    static let helmOpenArtifactFile = Notification.Name("helmOpenArtifactFile")
    /// ⌘⇧O — the sidebar presents the folder picker; the chosen folder becomes an
    /// open workspace. No payload: the panel runs at the receiver.
    static let helmOpenWorkspace = Notification.Name("helmOpenWorkspace")
    /// ⌘+/⌘-/⌘0 — object is a `FontSizeStep` raw value; the terminal
    /// workspace applies it to the selected terminal.
    static let helmAdjustFontSize = Notification.Name("helmAdjustFontSize")
    /// ⌘↑/⌘↓ — object is the prompt offset (-1 previous, +1 next); the
    /// terminal workspace forwards it to the selected terminal's surface.
    static let helmJumpToPrompt = Notification.Name("helmJumpToPrompt")
    /// ⌃1–⌃9 / ⌘⌥1–⌘⌥9 — object is the 0-based workspace index.
    static let helmSelectWorkspace = Notification.Name("helmSelectWorkspace")
    /// ⌃←/⌃→ — object is -1 / +1.
    static let helmCycleWorkspace = Notification.Name("helmCycleWorkspace")
}
