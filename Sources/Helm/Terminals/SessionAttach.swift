import Foundation
import HelmWire

/// How a pane shows an agent benchd runs (M3, #355): its terminal runs `bench attach <session>`
/// instead of a login shell. The agent lives in benchd's pty, so it keeps running while the pane
/// is hidden, the display sleeps or helm restarts; the pane is a view of it, and ends when it does.
///
/// The `bench` is the one beside the benchd helm follows (`status` names it), so the viewer is
/// always the daemon's own build. The pane's environment carries the suite (`PaneEnvironment`),
/// so it reaches the same root.
enum SessionAttach {
    /// The line ghostty runs for a pane showing `session`. It is run the way ghostty runs its own
    /// `command`, through the shell, so every word is quoted.
    static func command(session: String, bench: String) -> String {
        [bench, "attach", session].map(LaunchLine.quoted).joined(separator: " ")
    }
}

extension BenchDocument {
    /// The command for every terminal pane that shows a benchd session — each workspace's bench
    /// and every drawer. `bench` is benchd's own binary (`BenchClient.benchBinary`), asked for
    /// only when some pane shows a session, since asking is a round trip to benchd.
    func attachCommands(bench: @autoclosure () -> String) -> [UUID: String] {
        let panes =
            workspaces.flatMap { $0.bench.columns.flatMap(\.slots).flatMap(\.panes) }
            + drawers.flatMap(\.panes)
        let sessions = panes.compactMap { pane -> (UUID, String)? in
            guard case let .terminal(_, session?) = pane.surface else { return nil }
            return (pane.id, session)
        }
        guard !sessions.isEmpty else { return [:] }
        let bench = bench()
        return Dictionary(
            sessions.map { ($0.0, SessionAttach.command(session: $0.1, bench: bench)) },
            uniquingKeysWith: { first, _ in first })
    }
}
