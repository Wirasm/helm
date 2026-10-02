import Foundation

/// What the status bar says about where the operator is.
///
/// **Nothing here is computed, only selected.** The workspace and its branch already exist on
/// `WorkspaceModel`: two lookups on one key, no source and no timer. Who needs him is the
/// attention counts' (`AttentionCapsules`), not this.
///
/// A value rather than two reads in the view because the empty case is a rule: with no
/// workspace open there is no branch either, however stale a dictionary happens to be, and that
/// rule is worth a test.
struct StatusSummary: Equatable {
    /// The folder's name, or nil when nothing is open.
    let workspace: String?
    /// Its git branch, when it has one.
    let branch: String?

    /// **Private, so the rule above is checked rather than merely stated.** The synthesized
    /// memberwise initializer would happily build `StatusSummary(workspace: nil, branch: "main")`
    /// and nothing would object. Both real constructions live in this file.
    private init(workspace: String?, branch: String?) {
        self.workspace = workspace
        self.branch = branch
    }

    /// Nothing open: the bar's right-hand side goes empty rather than saying "none".
    static let none = StatusSummary(workspace: nil, branch: nil)

    /// The two lookups, on the selected workspace's path. "No workspace" is answered once, here.
    static func of(workspace: Workspace?, branches: [WorkspacePath: String]) -> StatusSummary {
        guard let workspace else { return .none }
        return StatusSummary(workspace: workspace.name, branch: branches[workspace.path])
    }
}
