import Foundation
import HelmWire

// MARK: - ResumableAgent

/// The agent that was running in a terminal pane when helm last looked (#63).
///
/// **A pane is helm's to recreate; a session is the CLI's.** `TerminalManager.activate`
/// already rebuilds a workspace's terminals under their persisted ids, and those shells come
/// back empty — the pty died with helm's process, and nothing helm owns can bring a
/// conversation back. What *can* is the agent's own `--resume`, and the only thing it needs
/// is an id helm was in a position to write down while the agent was alive. That is this
/// value, and it is the whole of what #63 adds to the persisted bench.
///
/// **On `Pane.Content.terminal`, not beside it.** A canvas has no agent, exactly as it has no
/// face, and asking one for either must not compile (`TerminalFace`'s header makes the same
/// argument). It also means restore is a straight read of the value the bench already
/// persists: no second store to keep in step, no map keyed by pane id that a closed pane
/// leaves a row in.
///
/// **What helm can see, and therefore what may be here.** `AgentRegistry` — Claude Code's own
/// `~/.claude/sessions/<pid>.json` — is the one runtime that publishes a pid→session mapping,
/// which is what lets helm say *this pane held that conversation*. pi keys its sessions by
/// cwd-slug and publishes no pid→session mapping at all (`MailboxDirectory.isRegistryBacked`
/// records the same boundary for the mailbox join), and codex publishes nothing helm reads. So
/// today only `claude` is ever written here. `command` is stored anyway rather than assumed,
/// for `AGENTS.md`'s discriminator rule: a second runtime should be a *value* this decoder
/// already carries, not a migration of every bench on disk — and `AgentResume` is where an
/// unknown one becomes a refusal the operator can read rather than a resume that fails in the
/// pane.
struct ResumableAgent: Codable, Equatable {
    /// The program to run again — a bare name from `SpoolPolicy.allowedCommands`'s family,
    /// and today always `claude`. Never a path: this is composed into a shell line, and the
    /// gate on what helm will start is the same gate a spawn passes.
    let command: String
    /// The agent's own id for the conversation — `AgentSession.sessionId`, the value
    /// `--resume` takes and the one that names the transcript on disk.
    let session: String
    /// Where it was working. Persisted rather than re-derived from the workspace, because an
    /// agent started in a subdirectory has a different `cwd` from the pane's workspace and it
    /// is the `cwd` that finds the transcript (`TranscriptLocator`).
    let cwd: String

    init(command: String, session: String, cwd: String) {
        self.command = command
        self.session = session
        self.cwd = cwd
    }

    /// What the offer shows instead of a 36-character uuid. Claude Code's own `/resume`
    /// picker abbreviates the same way, so this is the operator's existing vocabulary rather
    /// than helm's invention.
    var shortSession: String { String(session.prefix(8)) }
}

// MARK: - AgentResume

/// How helm asks an agent to pick a conversation back up, and what it tells it when it does.
///
/// **helm composes a command; it does not reimplement resume** (#63). Every line below is the
/// agent's own documented flag with helm's own id in it — nothing here parses a transcript,
/// replays a turn, or knows what a conversation is.
enum AgentResume {
    /// The one runtime helm can both observe and resume. See `ResumableAgent`'s header for why
    /// the list is one long and why the field is still stored.
    static let claude = "claude"

    /// **What the resumed agent is told, and why it is told anything at all.**
    ///
    /// An agent that resumes believing nothing happened acts on stale context — it is holding
    /// a plan whose subprocesses are dead, files half-written by a tool call that never
    /// returned, and teammates it will go on addressing. That, not the death itself, is the
    /// failure: Anthropic's own Agent Teams documents *"no session resumption for in-process
    /// teammates — the lead will try to message agents that no longer exist"* as its top
    /// limitation, and the answer their supervisor ships is to tell a resurrected session that
    /// it was resurrected. helm is in exactly that position and knows exactly the same fact.
    ///
    /// **One line, deliberately.** It is single-quoted onto a command line that libghostty
    /// delivers as a bracketed paste, so an embedded newline would arrive as a continuation
    /// the shell is still waiting on. helm composes this text itself — no caller supplies it —
    /// which is what makes an inline argument safe here where `SpoolLaunchLine` has to stage a
    /// caller's prompt in a file.
    static let notice =
        "helm restarted and resumed this session. Anything you had running is gone — "
        + "subprocesses, watches, and any teammates you were messaging no longer exist. "
        + "Re-check the state on disk before acting on anything you remember."

    /// The shell line that resumes `agent`, or nil when helm has no way to resume that
    /// runtime — which the offer turns into a sentence rather than a command that fails in
    /// the pane.
    ///
    /// # It changes directory first, and that is a measurement rather than a precaution
    ///
    /// A restored pane's pty is rooted at the **workspace** (`TerminalManager.activate`), and
    /// `ResumableAgent.cwd` is where the agent actually was — a subdirectory, whenever the
    /// operator started it in one. Measured 2026-08-07 against the real CLI, both halves,
    /// because the obvious reasoning gets one of them backwards:
    ///
    /// - **`--resume` is *not* cwd-scoped.** The same session id resolved from the parent
    ///   directory, from `$HOME` and from `/tmp`. So the transcript is found wherever the line
    ///   runs, and the offer's own transcript check is not what this is about.
    /// - **The resumed agent adopts the *process* cwd, not the session's.** Resumed from
    ///   `/tmp`, `pwd` answered `/tmp`. So without the `cd` an agent comes back in a directory
    ///   it never worked in — a different `CLAUDE.md`, a different git repository, and every
    ///   relative path in its own context now pointing somewhere else. It would run, look
    ///   healthy, and be wrong, which is the failure shape this whole area exists to remove.
    ///
    /// **Unconditional, and `&&` rather than `;`.** A `cd` to the directory the pane is already
    /// in costs nothing, and making it conditional would need the pane's cwd here, which this
    /// pure function does not have. `&&` is what makes a directory that no longer exists stop
    /// the line instead of starting an agent somewhere arbitrary — the operator clicked Resume,
    /// so they are at the pane and the shell's own error is in front of them.
    ///
    /// **It carries the same unattended posture a spawn does**, from
    /// `SpoolUnattendedPolicy` rather than a second spelling of it. The stretch is worth
    /// naming: that policy's header is written about the case where *nobody is at the pane*,
    /// and somebody just clicked Resume. The reason it still applies is the sentence
    /// underneath — those flags are the operator's own standing choice on this machine
    /// (`cls` is `claude --dangerously-skip-permissions`), and the agent being resumed was
    /// started with them. Resuming it into a different permission posture would hand back a
    /// different agent from the one that died, and would do it silently. Two spellings of
    /// "how helm starts claude" is the drift this repo has paid for before.
    static func line(
        resuming agent: ResumableAgent, notice: String? = AgentResume.notice
    )
        -> String?
    {
        guard agent.command == claude else { return nil }
        var parts = ["cd", SpoolLaunchLine.quoted(agent.cwd), "&&"]
        parts.append(SpoolLaunchLine.quoted(agent.command))
        parts.append(
            contentsOf: SpoolUnattendedPolicy.arguments(for: agent.command, requested: [])
                .map(SpoolLaunchLine.quoted))
        parts.append("--resume")
        parts.append(SpoolLaunchLine.quoted(agent.session))
        if let notice, !notice.isEmpty { parts.append(SpoolLaunchLine.quoted(notice)) }
        return parts.joined(separator: " ")
    }
}

// MARK: - AgentResumeOffer

/// The question one restored terminal pane asks: an agent was running here — resume it?
///
/// **A value, and not a persisted one.** The *record* of what was running is persisted
/// (`ResumableAgent`); the *question about it* is this launch's, and must not be — an offer
/// written to disk is an offer re-asked forever, including the one the operator already
/// declined. `WorkbenchModel` builds these at mount and drops each one when it is answered or
/// when the pane turns out to hold a live agent after all.
struct AgentResumeOffer: Equatable, Identifiable {
    /// Why helm will not run the resume, when it will not. nil is the offer.
    enum Blocked: Equatable {
        /// The agent's own transcript is no longer on disk, so `--resume` would fail. Claude
        /// Code's default retention is about 30 days (`cleanupPeriodDays`, unset).
        case transcriptGone
        /// helm has no resume line for that runtime. Unreachable from anything helm writes
        /// today — see `ResumableAgent` — and kept because a hand-edited bench, or a build
        /// that learns a second runtime before this one does, is exactly what
        /// `Pane.Content`'s unknown-`kind` branch exists for one level down.
        case runtimeUnknown(String)
    }

    let pane: Pane.ID
    let agent: ResumableAgent
    let blocked: Blocked?

    var id: Pane.ID { pane }
    var canResume: Bool { blocked == nil }

    /// The verdict on one restored pane, given only whether its transcript is still there.
    ///
    /// Pure, and the filesystem arrives as a closure, so every rule is reachable from
    /// `swift test` on a machine that has never run Claude Code — the same shape
    /// `SpoolPolicy.accept` takes `isDirectory` in.
    static func offer(
        _ agent: ResumableAgent, in pane: Pane.ID, transcriptExists: (ResumableAgent) -> Bool
    ) -> AgentResumeOffer {
        guard AgentResume.line(resuming: agent) != nil else {
            return AgentResumeOffer(
                pane: pane, agent: agent, blocked: .runtimeUnknown(agent.command))
        }
        return AgentResumeOffer(
            pane: pane, agent: agent,
            blocked: transcriptExists(agent) ? nil : .transcriptGone)
    }
}
