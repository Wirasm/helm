import AppKit

/// The folder panel behind ⇧⌘O, the workspace bar's `+` and the empty bench's button — one
/// panel, so the three cannot disagree about what opening a workspace asks.
@MainActor
enum WorkspacePanel {
    /// The folder the operator chose, or nil when he cancelled.
    static func choose() -> Workspace? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to work in"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Workspace(url: url)
    }
}
