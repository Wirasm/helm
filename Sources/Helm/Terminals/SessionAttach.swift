import Foundation
import HelmWire

/// How a pane shows an agent benchd runs (M3, #355): its terminal runs `bench attach <session>`
/// instead of a login shell. The agent lives in benchd's pty, so it keeps running while the pane
/// is hidden, the display sleeps or helm restarts; the pane is a view of it, and ends when it does.
///
/// The `bench` is an absolute path (`BenchExecutable`): the one beside the benchd helm follows
/// (`status` names it), so the viewer is the daemon's own build. The pane's environment carries
/// the suite (`PaneEnvironment`), so it reaches the same root.
enum SessionAttach {
    /// The line ghostty runs for a pane showing `session`. It is run the way ghostty runs its own
    /// `command`, through the shell, so every word is quoted. `--in-pane`: `bench attach` prints
    /// nothing of its own into the pane, and passes Ctrl-\ on (a shell's SIGQUIT) instead of
    /// detaching on it.
    /// What a terminal pane with no benchd session says. It starts nothing: helm owns no pty of
    /// its own (M5b), and a session comes back only through benchd.
    static let noSession =
        "This terminal has no session: benchd restarted, or its shell could not start. "
        + "Run `just resume-all` to bring every such pane back."

    static func command(session: String, bench: String) -> String {
        [bench, "attach", session, "--in-pane"].map(LaunchLine.quoted).joined(separator: " ")
    }
}

/// What a pane that shows a benchd session runs: `bench attach`, or, with no `bench` to run,
/// nothing, and the reason in the pane.
enum SessionLaunch: Equatable {
    case attach(command: String)
    case unavailable(reason: String)

    /// Whether `session` is already this launch: the same command, or the same reason shown.
    @MainActor
    func isShown(by session: TerminalSession) -> Bool {
        switch self {
        case let .attach(command): session.hostView.configuration.command == command
        case let .unavailable(reason): session.status == .unattachable(reason)
        }
    }
}

extension BenchDocument.Bench {
    /// The launch for every terminal pane on this bench that shows a benchd session. Asked of
    /// the bench being drawn only — its terminals are the ones helm starts — and `bench`
    /// (`AttachBench`) is asked for only when a pane here shows a session, since
    /// asking is a round trip to benchd.
    func attachCommands(
        bench: @autoclosure () -> Result<String, BenchExecutable.Unusable>
    ) -> [UUID: SessionLaunch] {
        let sessions = columns.flatMap(\.slots).flatMap(\.panes).compactMap {
            pane -> (UUID, String)? in
            guard case let .terminal(_, session?, _) = pane.surface else { return nil }
            return (pane.id, session)
        }
        guard !sessions.isEmpty else { return [:] }
        let launch: (String) -> SessionLaunch
        switch bench() {
        case let .success(bench):
            launch = { .attach(command: SessionAttach.command(session: $0, bench: bench)) }
        case let .failure(unusable):
            launch = { _ in .unavailable(reason: unusable.description) }
        }
        return Dictionary(
            sessions.map { ($0.0, launch($0.1)) }, uniquingKeysWith: { first, _ in first })
    }
}
