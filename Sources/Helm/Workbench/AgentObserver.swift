import Foundation

/// How helm learns which agent is in a pane (#63): Claude Code's registry, joined on the pid
/// that has the pane's terminal in benchd.
///
/// **One value rather than two parameters**: the lookups ride together from `WorkbenchModel`'s
/// initializer down to the tick that uses them, and it is what makes the rule reachable from
/// `swift test` — a fixture registry and a pid the test chose, on a machine that has never run
/// Claude Code and with nothing read out of the operator's own `~/.claude`.
///
/// **Claude Code only, and that is `AgentRegistry`'s boundary rather than a new one.** It is
/// the one runtime that publishes a pid→session mapping. `ResumableAgent`'s header has the rest.
@MainActor
struct AgentObserver {
    /// Every registry row on the machine right now, by pid.
    ///
    /// A closure returning a fresh dictionary rather than a stored one: an agent's row appears
    /// while helm is running — that is the event this whole watch exists to notice — so an
    /// answer captured earlier could never see it.
    let sessionsNow: () -> [pid_t: AgentSession]

    /// What has a terminal pane's terminal in benchd. Injected because a test has no benchd to
    /// ask, exactly as `BenchSnapshotModel` injects it.
    let foregroundPid: (TerminalSession) -> pid_t?

    /// The live wiring — Claude Code's registry, and benchd's view of each pane's terminal.
    static func live(registryRoot: URL = AgentRegistry.defaultRoot) -> AgentObserver {
        AgentObserver(
            // `AgentRegistry.rows`, never a dictionary built here: one rule for a duplicate pid.
            // That function's header has why.
            sessionsNow: { AgentRegistry.rows(in: registryRoot) },
            foregroundPid: { $0.foregroundPid })
    }
}
