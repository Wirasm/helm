import Foundation

/// What helm writes back about a request, at `results/<id>.json`.
///
/// **A request channel with no response is half a protocol.** Without this the caller learns
/// which agent it started by polling `~/.claude/sessions/` for *"a new row whose pid descends
/// from that terminal and whose cwd matches"* — which is what `helm-spawn` does, and it is a
/// heuristic: two agents starting in one directory at the same time misattribute, and a
/// worktree makes that ordinary rather than exotic. helm is the one party that cannot get it
/// wrong, because it created the terminal and therefore knows the pid.
///
/// **Results live in their own directory** because the request file is deleted on claim. The
/// response has to outlive it, and exactly-once still holds.
struct SpoolResult: Codable, Equatable {
    /// The life of one request, as the caller sees it.
    ///
    /// **`started` and `ready` are two writes to one file, and that is the design decision
    /// #54 asks to be made explicitly.** A mailbox is claimed by the agent's own
    /// `SessionStart` hook *after* the session comes up, so at the moment helm has a terminal
    /// there is no `owner.json` yet and no handle to report. The issue lists three answers:
    /// wait for the claim before writing anything; write twice; or make the caller resolve it.
    ///
    /// This is the second, for one reason that outranks the others: **a refusal and a slow
    /// start must never look the same from outside.** Waiting for the claim means an accepted
    /// request writes nothing for as long as an agent takes to boot, which is indistinguishable
    /// from helm not running, from the request never being seen, and from a watcher that is
    /// switched off. Writing `started` within milliseconds says *"I have this, here is your
    /// terminal"* and leaves only one thing outstanding. The cost is real and is paid by the
    /// caller: it waits for a **change**, not for a file to appear. `tools/helm-spool.swift`
    /// absorbs that, which is what a small CLI is for.
    ///
    /// The third answer — the caller resolves the handle — is the one this type exists to
    /// avoid: it puts the `~/.helm/mail` scan back into every caller, and a caller that gets
    /// it wrong gets it silently wrong (see `MailboxDirectory`).
    enum Status: String, Codable {
        /// A terminal exists in helm and the launch line has been written into its pty. No
        /// handle yet — the agent has not claimed a mailbox.
        case started
        /// The agent claimed a mailbox. `pid`, `sessionId`, `handle` and `runtime` are real,
        /// and the caller can address it now.
        case ready
        /// The terminal is alive but no mailbox appeared before the deadline. Deliberately
        /// **not** a failure and deliberately not cleaned up: the agent may be running
        /// perfectly well without the mail hooks installed. It exists; it cannot be
        /// addressed; `reason` says so.
        case unclaimed
        /// The request was read and refused — a command outside the allowlist, a cwd that is
        /// not there, an unparseable file. Nothing was started.
        case refused
        /// helm accepted the request and could not carry it out. `reason` says why.
        case failed
        /// The request was claimed, helm stopped before acting, and it was **not** re-run on
        /// restart. Exactly-once is the promise; a re-run after a crash mid-spawn is precisely
        /// the double-open #54 forbids. So the caller is told rather than left waiting.
        case abandoned
    }

    let id: String
    var status: Status
    /// `TerminalSession.id` — the same uuid the pane is persisted under, and the same one the
    /// child reads as `HELM_PANE` (`PaneEnvironment`).
    var terminalId: String?
    /// The pty's foreground pid once the agent is running. helm knows this authoritatively.
    var pid: Int32?
    /// The agent's own id for its session, read out of `owner.json` — never guessed at.
    var sessionId: String?
    /// The mailbox address, so the caller's next move ("now tell it something") needs no
    /// lookup of its own. **Read, never derived** — see `MailboxDirectory`.
    var handle: String?
    /// `claude` or `pi`, as the mailbox reports it. One lookup answers for both runtimes,
    /// where the Claude session registry answers for only one.
    var runtime: String?
    /// Why, on any status that is not a plain success. Present on `refused`, `failed`,
    /// `abandoned` and `unclaimed`.
    var reason: String?
    /// Seconds since the epoch, so a caller watching for the `started` → `ready` change has
    /// something that always differs between the two writes.
    var updatedAt: Double

    init(
        id: String, status: Status, terminalId: String? = nil, pid: Int32? = nil,
        sessionId: String? = nil, handle: String? = nil, runtime: String? = nil,
        reason: String? = nil, updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.status = status
        self.terminalId = terminalId
        self.pid = pid
        self.sessionId = sessionId
        self.handle = handle
        self.runtime = runtime
        self.reason = reason
        self.updatedAt = updatedAt
    }
}
