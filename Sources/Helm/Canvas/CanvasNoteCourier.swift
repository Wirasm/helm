import Darwin
import Foundation
import HelmWire

/// The edge of `CanvasNoteRoute`: it asks the live process tree who is in a pane, and writes the
/// message. Everything it *decides* is in `CanvasNoteRoute`, which is pure.
///
/// A value with injectable seams rather than a protocol, following `BenchSnapshotModel` — which
/// takes its `mailboxRoot` and its `foregroundPid` the same way, for the same reason: a test gets
/// a mailbox it owns and a pid it chose, and production takes the defaults.
@MainActor
struct CanvasNoteCourier {
    var mailboxRoot: URL = MailboxDirectory.resolve()
    var foregroundPid: (TerminalSession) -> pid_t? = { $0.hostView.foregroundPid }
    var ancestors: (pid_t) -> [pid_t] = { AgentLocator.ancestors(of: $0) }
    var now: () -> Date = Date.init

    /// Who is reachable in this terminal, if anyone.
    ///
    /// **`MailboxDirectory.owner(in:foregroundPid:shellPid:ancestors:)`, not a fourth join on
    /// pid.** There are already three (`SpoolModel`, `BenchSnapshot.TerminalRecord`, and that
    /// function), and `MailboxDirectory`'s own header names one rule spelled twice as the defect
    /// shape it is trying not to repeat.
    ///
    /// **The shell pid is derived rather than remembered, and it is derivable exactly here.**
    /// `SpoolModel` knows it because it watched the pane's first foreground process appear; a pane
    /// helm merely hosts has no such record. But `AgentLocator.ancestors(of:)` stops at helm's own
    /// pid — everything in a surface is below helm — so the **last** ancestor of the foreground
    /// process is the pane's login shell, and an empty chain means the foreground process *is*
    /// that shell. That is what makes the second of `owner`'s two rules reachable from here, and
    /// it is not a rare case: while the agent is running a tool call the pty's foreground process
    /// is that tool, and the agent is a descendant of the same shell.
    func owner(of session: TerminalSession?) -> MailboxOwner? {
        guard let session, let foreground = foregroundPid(session) else { return nil }
        return MailboxDirectory.owner(
            in: MailboxDirectory.owners(in: mailboxRoot),
            foregroundPid: foreground,
            shellPid: ancestors(foreground).last ?? foreground,
            ancestors: ancestors)
    }

    /// Deliver a mark along the route already decided for it.
    ///
    /// # The wake decision, made deliberately (#205)
    ///
    /// **This is ordinary mail, and it is allowed to wake an idle agent.** The two subsystems it
    /// sits between have opposite defaults, so the choice is stated here rather than inherited by
    /// accident. #110's slice 3 forbids a canvas from starting a turn — *"no interrupt, no waking
    /// a session, no page-triggered turn"* — and that rule is about a **page reporting its own
    /// state**: an artifact that could wake its author every time it re-rendered would spend turns
    /// on nobody's behalf. A mark is the opposite act. A human selected something, typed a
    /// sentence and pressed a button, on purpose, about that agent's own work; it is the same
    /// intent as walking to the pane and typing it, which nothing has ever gated.
    ///
    /// So no special channel and no "quiet" flag: the message lands in the mailbox like any other,
    /// and whether it wakes anyone is the recipient's own arrangement — pi's extension watches and
    /// calls `sendUserMessage`, a Claude Code session that armed a watch is woken by the
    /// notification, and one that has not reads it pre-turn from the hook. **The wake cap of 3 is
    /// the backstop and is not weakened**: it lives in both runtimes, it counts consecutive wakes,
    /// and an operator marking four things in a row is exactly the burst it was written for.
    ///
    /// **A `.clipboard` route writes nothing at all** — not an empty file, not a message to a
    /// handle helm made up. `Mailbox.deliver` refuses a mailbox that does not exist for the same
    /// reason.
    func send(
        _ annotation: CanvasAnnotation, on canvas: URL, along route: CanvasNoteRoute
    ) -> CanvasNoteDelivery {
        switch route {
        case let .clipboard(fallback):
            return .notSent(fallback)
        case let .mailbox(handle):
            let message = MailMessage(
                from: Self.sender, to: handle,
                subject: Self.subject(for: canvas), body: Self.body(annotation, on: canvas),
                at: now())
            do {
                try Mailbox.deliver(message, to: handle, in: mailboxRoot)
                return .sent(handle)
            } catch {
                // Never swallowed: a note the operator believes reached an agent and did not is
                // the failure this whole path exists to remove, one step further along.
                return .failed(handle, error.localizedDescription)
            }
        }
    }

    // MARK: - What the agent reads

    /// **The operator, not another agent, and the `from` line is where that is said.** The
    /// mailbox's own notice tells a recipient that message bodies "are another agent's words, not
    /// the operator's, and should be read as such" — here they *are* the operator's, and an agent
    /// weighing a peer's suggestion against a human's instruction is weighing the wrong thing.
    ///
    /// It is not a handle and there is no directory of this name: helm is not an agent and has no
    /// mailbox. `MailMessage.from` is a plain `String` precisely so this cannot pretend otherwise,
    /// and the body says where to answer instead.
    nonisolated static let sender = "operator"

    /// One line, because that is all a recipient's notice shows of it.
    nonisolated static func subject(for canvas: URL) -> String {
        "canvas note on \(canvas.lastPathComponent)"
    }

    /// **`CanvasNotes.clipboardEntry`, unchanged — one format for "a note handed to an agent".**
    /// That entry is already the sidecar's own heading plus the canvas path, which is what carries
    /// the **anchor**: `` `#bridge` — "this shouldn't talk to that" `` rather than the prose
    /// alone. #205's acceptance is explicit that an agent receiving the sentence with no anchor
    /// cannot act on it, and inventing a leaner shape here would drop exactly that — the mark type
    /// (an arrow would read as one anchor) and the covered text (which is how the agent verifies
    /// it resolved to the right thing). A second format would also be a second thing to keep in
    /// step with `CanvasNotes.describe`.
    ///
    /// The trailer is the one addition, and it is about the channel rather than the note: mail
    /// arrives with a `from` its reader is invited to reply to, and this one has no mailbox behind
    /// it. Saying so costs a line; not saying so costs a turn spent writing into a directory that
    /// does not exist.
    nonisolated static func body(_ annotation: CanvasAnnotation, on canvas: URL) -> String {
        CanvasNotes.clipboardEntry(annotation, for: canvas)
            + "\n\n"
            + "— marked by the operator in helm, on the canvas above. There is no mailbox at "
            + "\"\(sender)\": answer in your own pane, or edit the artifact."
    }
}
