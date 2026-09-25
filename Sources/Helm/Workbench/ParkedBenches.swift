/// The benches of workspaces that are not mounted, as far as `WorkbenchModel` needs them (#349).
///
/// A parked workspace's arrangement is a value `WorkspaceModel` stores and restores from, and the
/// live bench cannot reach it. An agent in one of its panes can still push, because a push comes
/// from terminal output and parked terminals keep running. This is the one thing the live bench
/// asks of that store: put this canvas on that workspace's bench, the way `offer` would.
@MainActor
protocol ParkedBenches: AnyObject {
    /// Offer `source` onto the stored bench of the workspace at `path`, without selecting it or
    /// moving focus (`Workbench.offer(canvas:)`). Returns the pane now showing it, or nil when
    /// that workspace has no stored bench to put it on.
    func offer(_ source: CanvasSource, toBenchOf path: WorkspacePath) -> Pane.ID?
}
