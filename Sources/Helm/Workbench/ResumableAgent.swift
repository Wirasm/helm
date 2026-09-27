import Foundation
import HelmWire

// MARK: - ResumableAgent

/// The agent that was running in a terminal pane when helm last looked (#63): what `bench
/// restore` resumes in that pane after benchd restarts (M5b, `just resume-all`).
///
/// **On `Pane.Content.terminal`, not beside it.** A canvas has no agent, and asking one for its
/// agent must not compile. The record is benchd's document's (`Surface::Terminal::agent`); helm
/// writes it with `pane/record` from what it observes (`WorkbenchModel.observeAgents`).
///
/// **What helm can see, and therefore what may be here.** `AgentRegistry` — Claude Code's own
/// `~/.claude/sessions/<pid>.json` — is the one runtime that publishes a pid→session mapping,
/// which is what lets helm say *this pane held that conversation*. So today helm writes only
/// `claude` here; benchd writes the others for the agents it spawns. `command` is stored rather
/// than assumed, for `AGENTS.md`'s discriminator rule.
struct ResumableAgent: Codable, Equatable {
    /// The program — a bare agent name (`claude`, `codex`, `pi`), the set benchd spawns.
    let command: String
    /// The agent's own id for the conversation — `AgentSession.sessionId`, the value its resume
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

enum AgentResume {
    /// The one runtime helm observes in a pane. See `ResumableAgent`'s header.
    static let claude = "claude"
}
