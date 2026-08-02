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
    /// The canvas takes a URL. Object is the URL to open, or nil — which is ⌘L,
    /// meaning "show me the address field", whether the canvas is open or not.
    ///
    /// The payload form has no poster in the tree yet. It is what the terminal's
    /// ⌘-click would post for an http link (`TerminalSession.terminalDidRequestOpenURL`
    /// hands those to `NSWorkspace` today, i.e. out of the app); repointing it is
    /// one line and needs nothing further from the canvas.
    static let helmOpenCanvasURL = Notification.Name("helmOpenCanvasURL")
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
    /// ⌘T — swap the terminal pane between its two faces: the terminal, and the
    /// agent's writing drawn over it. No payload; it is a toggle.
    static let helmToggleChat = Notification.Name("helmToggleChat")
}
