import Foundation
import HelmWire

/// The edge of `CanvasNoteRoute`: it asks benchd who is in a pane, and sends the message there.
/// Everything it *decides* is in `CanvasNoteRoute`, which is pure.
///
/// helm keeps no mailroom (#358). The agent in a pane has an address once its harness reports
/// to benchd, and `mail/who` names it; a test hands in a `BenchMailbox` that answers as it likes.
@MainActor
struct CanvasNoteCourier {
    var mail: BenchMailbox = .live()

    /// Who is reachable in this pane, if anyone: the agent whose hook last reported from it.
    func handle(in pane: Pane.ID) -> Handle? {
        mail.who(pane)?.handle
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
    /// and benchd delivers it by the agent's state — at its next tool call if it is busy, or by
    /// starting a turn if it is idle. **benchd's wake cap is the backstop and is not weakened**:
    /// an operator marking seven things in a row is exactly the burst it was written for.
    ///
    /// **A `.clipboard` route sends nothing at all** — not a message to a handle helm made up.
    func send(
        _ annotation: CanvasAnnotation, on canvas: URL, along route: CanvasNoteRoute
    ) -> CanvasNoteDelivery {
        switch route {
        case let .clipboard(fallback):
            return .notSent(fallback)
        case let .mailbox(handle):
            do {
                try mail.send(
                    handle, Self.sender, Self.subject(for: canvas),
                    Self.body(annotation, on: canvas))
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
    /// mailbox's notice used to tell every recipient that message bodies "are another agent's
    /// words, not the operator's, and should be read as such" — which was right for agent mail and
    /// backwards for this sender, and an agent weighing a peer's suggestion against a human's
    /// instruction is weighing the wrong thing. That was #257, and this line is what it was filed
    /// against: the `from` carried the truth while the sentence the reader trusts at a glance
    /// contradicted it.
    ///
    /// `operator` is a reserved handle on the bench, so no agent can *be* this sender, and the
    /// notice names it (`You have mail from operator: …`). It is still not authentication: `from`
    /// is a field any sender sets. The operator's mailbox exists in benchd, but helm does not
    /// read it for him, so the body says where to answer instead.
    nonisolated static let sender = "operator"

    /// One line, because that is all a recipient's notice shows of it.
    nonisolated static func subject(for canvas: URL) -> String {
        "canvas note on \(canvas.lastPathComponent)"
    }

    /// **`CanvasNotes.clipboardEntry`, unchanged — one format for "a note handed to an agent".**
    /// That entry is already the sidecar's own heading plus the canvas path, which is what carries
    /// the **anchor**: `` `#bridge` — "this shouldn't talk to that" `` rather than the prose
    /// alone. #205's acceptance is explicit that an agent receiving the sentence with no anchor
    /// cannot act on it, and inventing a leaner shape here would drop exactly that — and the
    /// covered text, which is how the agent verifies it resolved to the right thing. A second format would also be a second thing to keep in
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
