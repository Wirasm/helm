import Foundation
import HelmWire

// MARK: - ResumableAgent

/// The agent that was running in a terminal pane when helm last looked (#63): what `bench
/// restore` resumes in that pane after benchd restarts (M5b, `just resume-all`).
///
/// **On `Pane.Content.terminal`, not beside it.** A canvas has no agent, and asking one for its
/// agent must not compile. The record is benchd's document's (`Surface::Terminal::agent`); helm
/// reads it; benchd writes it from each agent's own hook (M5b).
///
/// Every harness reports through its own hook, so this holds claude, codex or pi alike.
struct ResumableAgent: Codable, Equatable {
    /// The program — a bare agent name (`claude`, `codex`, `pi`), the set benchd spawns.
    let command: String
    /// The agent's own id for the conversation, as its hook reported it: the value its resume
    /// flag takes.
    let session: String
    /// Where it was working: an agent started in a subdirectory resumes there, not in the
    /// workspace.
    let cwd: String

    init(command: String, session: String, cwd: String) {
        self.command = command
        self.session = session
        self.cwd = cwd
    }
}
