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

extension BenchDocument.Bench {
    /// The command for every terminal pane on this bench that shows a benchd session. Asked of
    /// the bench being drawn only — its terminals are the ones helm starts — and `bench` (benchd's
    /// own binary, `BenchClient.benchBinary`) is asked for only when a pane here shows a session,
    /// since asking is a round trip to benchd.
    func attachCommands(bench: @autoclosure () -> String) -> [UUID: String] {
        let sessions = columns.flatMap(\.slots).flatMap(\.panes).compactMap {
            pane -> (UUID, String)? in
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
