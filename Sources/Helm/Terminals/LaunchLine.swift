import Foundation

/// A line helm types into a terminal it owns: #85's resume offer, which re-enters an agent's
/// conversation in a restored pane when the operator accepts it (`ResumableAgent`), and the
/// sessions drawer's open actions (`SessionsModel`).
/// An agent spawned by `bench spawn` never passes through here; benchd starts it in its own pty
/// with the same postures (`bench_session::argv`).
///
/// The line is pasted, then submitted with a separate Return (`TerminalLaunchLine.send`):
/// libghostty wraps every `sendText` in bracketed-paste markers when the shell has mode 2004 on,
/// so a trailing `\r` would sit on the command line unsubmitted.
enum LaunchLine {
    /// POSIX single-quoting: everything inside is literal, and an embedded `'` is closed,
    /// escaped and reopened. The only escaping rule a shell has no exceptions to.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What each agent runs with when nobody may be at the pane: the operator's own standing choice
/// (#179). A bare `claude` stops at a permission prompt, and a prompt in a pane nobody watches is
/// indistinguishable from an agent that never started. **A posture removes a prompt; it never
/// withholds capability** — blocking belongs in hooks and sandboxes, and the operator's gate is
/// the pull request.
///
/// - `claude` → `--dangerously-skip-permissions`: what his `cls` runs.
/// - `codex` → `-p yolo`: what his `cdxy` runs (`approval_policy = "never"`, full access).
/// - `pi` → `--approve`: it only ever asks whether to load the project's own settings, and
///   declining would start it without the context it was pointed at.
///
/// **A posture cannot remove every prompt (#283).** Claude Code keeps some guardrails
/// bypass-immune under any flag — a dangerous `rm` among them — and one sat at a pane for six and
/// a half hours. There is no flag to add here; a stalled agent is found by its own `waiting`
/// report (`BenchSnapshot.AgentRecord`, `bench sessions --all`).
enum UnattendedPosture {
    struct Posture: Equatable {
        /// Prepended to the line's own arguments.
        let arguments: [String]
        /// Flags meaning the caller already decided, so nothing is added. Matched on the flag
        /// name alone, so `--permission-mode plan` and `--permission-mode=plan` both count.
        let settled: Set<String>
    }

    static let postures: [String: Posture] = [
        "claude": Posture(
            arguments: ["--dangerously-skip-permissions"],
            settled: ["--dangerously-skip-permissions", "--permission-mode"]),
        "codex": Posture(
            arguments: ["-p", "yolo"],
            settled: [
                "-a", "--ask-for-approval", "--dangerously-bypass-approvals-and-sandbox",
                "-p", "--profile",
            ]),
        "pi": Posture(
            arguments: ["--approve"],
            settled: ["-a", "--approve", "-na", "--no-approve"]),
    ]

    /// The arguments to run, given what was asked for. `settled` is matched against `requested`
    /// alone, never the composed line: codex's posture is itself `-p`, and checking the result
    /// would have helm's own `-p` cancel its own posture.
    static func arguments(for command: String, requested: [String]) -> [String] {
        guard let posture = postures[command] else { return requested }
        let named = Set(requested.map { String($0.prefix { $0 != "=" }) })
        guard named.isDisjoint(with: posture.settled) else { return requested }
        return posture.arguments + requested
    }
}
