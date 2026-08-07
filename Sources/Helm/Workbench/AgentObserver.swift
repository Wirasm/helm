import Foundation

/// How helm learns which agent is in a pane, and whether that agent's conversation is still
/// on disk (#63).
///
/// **One value rather than three parameters**, for `AddressBook`'s reason: the three lookups
/// ride together from `WorkbenchModel`'s initializer down to the tick that uses them, and
/// parallel parameters kept in step by habit is a shape this repo has been bitten by. It is
/// also what makes every rule above it reachable from `swift test` — a fixture registry, a
/// fixture transcript store, and a pid the test chose, on a machine that has never run Claude
/// Code and with nothing read out of the operator's own `~/.claude`.
///
/// **Claude Code only, and that is `AgentRegistry`'s boundary rather than a new one.** It is
/// the one runtime that publishes a pid→session mapping, which is the only thing that can
/// answer *which conversation was in this pane*. pi keys its sessions by cwd-slug and
/// publishes no such mapping; codex publishes nothing helm reads. `ResumableAgent`'s header
/// has the full argument, including why the record still stores the command.
@MainActor
struct AgentObserver {
    /// Every registry row on the machine right now, by pid.
    ///
    /// A closure returning a fresh dictionary rather than a stored one: an agent's row appears
    /// while helm is running — that is the event this whole watch exists to notice — so an
    /// answer captured earlier could never see it. `AgentRegistry.sessionLookup`'s header
    /// makes the same point about the same file.
    let sessionsNow: () -> [pid_t: AgentSession]

    /// The pty's foreground process for a terminal. Injected because a test has no ghostty
    /// surface to ask, exactly as `BenchSnapshotModel` injects it.
    let foregroundPid: (TerminalSession) -> pid_t?

    /// Whether the agent's own transcript is still where its runtime keeps it.
    ///
    /// **The half of #63 that stops helm offering a resume that will fail.** Claude Code
    /// prunes transcripts on `cleanupPeriodDays` — about 30 days by default — so a bench
    /// restored after a long gap names sessions that cannot come back. Saying so is a
    /// sentence; offering it anyway is a shell that prints an error into a pane nobody was
    /// looking at.
    let transcriptExists: (ResumableAgent) -> Bool

    /// The live wiring — Claude Code's registry, a real pty, and the transcript store.
    static func live(
        registryRoot: URL = AgentRegistry.defaultRoot,
        transcriptRoot: URL = TranscriptLocator.defaultRoot
    ) -> AgentObserver {
        AgentObserver(
            // `AgentRegistry.rows`, never a dictionary built here. It is the registry's own
            // pid→row step, and building a second one is how this shipped a first draft where
            // `sessionLookup` kept the *first* row for a duplicate pid and this kept the
            // *last* — one rule, two spellings, and `snapshot.json` able to name a different
            // session from the one the pane's own record held. That function's header has the
            // measurement.
            sessionsNow: { AgentRegistry.rows(in: registryRoot) },
            foregroundPid: { $0.hostView.foregroundPid },
            transcriptExists: { Self.transcriptExists($0, root: transcriptRoot) })
    }

    /// Whether `agent` still has a transcript to resume from.
    ///
    /// **Only a runtime helm can actually check.** `TranscriptLocator` reads Claude Code's
    /// store and nothing else, so anything else is reported as present rather than as gone:
    /// helm not knowing must never present itself as helm knowing the answer is no. Today
    /// nothing but `claude` can reach here at all (`ResumableAgent`), and a runtime helm
    /// cannot resume is refused earlier and for a different reason
    /// (`AgentResumeOffer.Blocked.runtimeUnknown`).
    static func transcriptExists(_ agent: ResumableAgent, root: URL) -> Bool {
        guard agent.command == AgentResume.claude else { return true }
        return TranscriptLocator.transcript(
            forSession: agent.session, cwd: agent.cwd, root: root) != nil
    }
}
