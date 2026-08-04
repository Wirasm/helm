import Foundation

/// Every app-level command helm posts. A vertical listens for the ones it owns;
/// `Shortcut` maps keys onto them and `HelmCommands` puts the mirrored ones in the menu.
extension Notification.Name {
    /// ⌘N — TerminalManager appends and selects a fresh login shell.
    static let helmNewTerminal = Notification.Name("helmNewTerminal")
    /// ⌘1–⌘9 — object is the 0-based tab index to select.
    static let helmSelectTerminal = Notification.Name("helmSelectTerminal")
    /// ⌘O — the canvas presents its open panel.
    static let helmOpenArtifact = Notification.Name("helmOpenArtifact")
    /// A ⌘-click on an OSC 8 link the agent printed — object is the `file:` URL to
    /// render in the canvas. Distinct from `helmOpenArtifact`, which is the
    /// payload-less ⌘O that summons the picker.
    static let helmOpenCanvasFile = Notification.Name("helmOpenCanvasFile")
    /// An agent pushing an artifact onto the bench — object is the `file:` URL. Distinct
    /// from `helmOpenCanvasFile`, which is the operator asking: a push **appears** as a
    /// tab without selecting it or moving focus, because the operator did not ask for it
    /// and may be mid-thought in another pane (#125).
    static let helmPushCanvasFile = Notification.Name("helmPushCanvasFile")
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
    /// ⌘T — swap the **focused pane's** two faces: the terminal, and the agent's
    /// writing drawn over it. No payload; it is a toggle.
    ///
    /// The name and the key are unchanged from #37; only the receiver moved, from a
    /// `@State` on `TerminalWorkspace` to `WorkbenchModel`. It has to reach a pane whose
    /// view may be mounted, unmounted or not yet built, which is why it cannot be view
    /// state under a bench.
    static let helmToggleChat = Notification.Name("helmToggleChat")
    /// ⌘D — a new column right of the focused one, holding a fresh terminal.
    static let helmSplitRight = Notification.Name("helmSplitRight")
    /// ⌘⇧D — a new row under the focused slot, holding a fresh terminal.
    static let helmSplitDown = Notification.Name("helmSplitDown")
    /// ⌘⌥W — close the focused pane. ⌘W is unavailable: SwiftUI's `WindowGroup` binds it
    /// to close-window.
    static let helmClosePane = Notification.Name("helmClosePane")
    /// ⌘⌥←/→/↑/↓ — object is a `Workbench.Direction` raw value.
    static let helmMoveFocus = Notification.Name("helmMoveFocus")
    /// A canvas's `Post`: prefill a composer with text. Object is a `ComposeRequest`.
    static let helmComposeText = Notification.Name("helmComposeText")
    /// ⇧⌘R — show or hide the remembered Archon monitor rail.
    static let helmToggleRail = Notification.Name("helmToggleRail")
}

/// Text offered to one pane's composer.
///
/// **Addressed, and that is the point.** The composer lives inside `ChatOverlay`, so under
/// a bench an unaddressed notification would prefill every open chat face at once. Which
/// pane is the bench's decision (`WorkbenchModel.composeTarget`); this only carries it.
struct ComposeRequest {
    let pane: Pane.ID
    let text: String
}
