import Foundation

/// What the status bar says about where the operator is.
///
/// **Nothing here is computed, only selected.** The workspace and its branch already exist
/// on `WorkspaceModel`; the agent mark is already computed by `BoardModel`, which polls on
/// the workspace bar's behalf. This adds no source, no timer and no work — three lookups on
/// one key. A status bar that had to *measure* something to fill itself would be a status
/// bar that costs the terminal frames, and the terminal is the point.
///
/// A value rather than three reads in the view because the empty cases are a rule: with no
/// workspace open there is no branch and no agent either, however stale a dictionary
/// happens to be, and that rule is worth a test.
struct StatusSummary: Equatable {
    /// The folder's name, or nil when nothing is open.
    let workspace: String?
    /// Its git branch, when it has one and it has been resolved.
    let branch: String?
    /// Whether an agent in this workspace is working, or has stopped and wants you.
    let agents: AgentPresence?

    /// **Private, so the rule above is checked rather than merely stated.** The synthesized
    /// memberwise initializer would happily build the state this type exists to rule out —
    /// `StatusSummary(workspace: nil, branch: "main", agents: .working)` — and nothing would
    /// object. Both real constructions live in this file, so closing it costs nothing.
    private init(workspace: String?, branch: String?, agents: AgentPresence?) {
        self.workspace = workspace
        self.branch = branch
        self.agents = agents
    }

    /// Nothing open: the bar's right-hand side goes empty rather than saying "none".
    static let none = StatusSummary(workspace: nil, branch: nil, agents: nil)

    /// The three lookups, on the selected workspace's path.
    ///
    /// Takes the whole dictionaries rather than pre-resolved values so the caller has no
    /// key to get wrong, and so "no workspace" is answered once, here.
    static func of(
        workspace: Workspace?,
        contexts: [String: WorkspaceContext],
        presence: [String: AgentPresence]
    ) -> StatusSummary {
        guard let workspace else { return .none }
        let branch = contexts[workspace.path.value]?.branch
        return StatusSummary(
            workspace: workspace.name,
            // An empty string is not a branch. `cacheBranch` already stores nil for a
            // folder that is not a repository, but a persisted context predates that
            // guard and would render as a gap with a separator on either side.
            branch: (branch?.isEmpty ?? true) ? nil : branch,
            agents: presence[workspace.path.value]
        )
    }

    /// The word for the mark, or nil where there is no agent to speak for.
    ///
    /// It says the same two things `AgentDot` does, in the one place there is room for
    /// words — the dot is what a workspace tab can afford, this is what a bar can.
    var agentLabel: String? {
        switch agents {
        case .none: nil
        case .working: "working"
        case .notWorking: "your turn"
        }
    }
}
