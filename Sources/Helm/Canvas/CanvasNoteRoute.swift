import Foundation
import HelmWire

// MARK: - CanvasOrigin

/// The terminal that put a canvas on the bench.
///
/// **The identity existed at push time and was thrown away** (#205, and #210's second seam).
/// `TerminalSession.terminalDidRequestDesktopNotification` classifies the push with the session
/// — and therefore its pid, and therefore its mailbox — right there in scope, and
/// `CanvasPushRequest` carried `{artifact, workspacePath}` onward. So a mark made on that canvas
/// had no route home and ended at the operator's clipboard, which is #115's own measurement of
/// why marking lost to typing.
///
/// **A newtype over the pane id rather than a bare `UUID`, and that is not decoration here.** The
/// map this appears in is `[Pane.ID: CanvasOrigin]` — canvas pane to terminal pane — and both
/// sides are `UUID`. `AGENTS.md` asks for the newtype the day the comment gets written; this is
/// that day, and the comment would have read "the key is the canvas, the value is the terminal".
///
/// **Resolved late, never at push time.** What is recorded is which pane, not which pid or which
/// handle: a handle read when the push arrived would be stale the moment that agent restarted in
/// the same pane, and stale silently — mail to a retired mailbox is never read and never bounces
/// (`MailboxDirectory.owners(in:)`). Asking the pane who is in it *now*, at the moment the
/// operator marks something, is the only answer that cannot be quietly wrong.
///
/// **Which is also why it is not persisted.** A restored terminal pane is a fresh empty shell —
/// *attach never own*, `Pane.Content`'s encoder says so in as many words — so after a relaunch the
/// agent that pushed the canvas is gone by construction. An origin that survived the restart could
/// only name a pane running somebody else.
struct CanvasOrigin: Equatable, Hashable {
    /// The terminal pane, which for a terminal *is* its `TerminalSession.ID` (`Pane`'s header).
    let terminal: Pane.ID
}

// MARK: - CanvasNoteRoute

/// Where an operator's mark goes once it is written down.
///
/// **Pure, and the whole decision.** #205's acceptance asks for a test over the routing decision
/// rather than over a note posted by hand, and this is the shape that makes one possible: the
/// owner lookup is a closure, so the rule is a test that spawns no process and touches no
/// mailbox. `AgentLocator` splits itself the same way and for the same reason.
enum CanvasNoteRoute: Equatable {
    /// The agent that pushed this canvas, still reachable.
    case mailbox(Handle)
    /// Nobody to send to. The note is on the clipboard, exactly as before this existed, and the
    /// pane says which of these it was — **a silent no-op here is the worst outcome**, because
    /// the operator believes the note was sent.
    case clipboard(Fallback)

    enum Fallback: Equatable {
        /// No agent pushed this canvas: the operator opened it themselves, or a restart dropped
        /// the origin that named one.
        case noOrigin
        /// An agent pushed it, and there is no mailbox for that pane any more — the pane was
        /// closed, the session ended, or the agent never claimed one.
        case originGone
    }

    /// **`origin == nil` and `owner == nil` are different answers, and the operator is told
    /// which.** They read identically from the outside — no mail either way — and collapsing them
    /// would leave "why did nothing send?" unanswerable at exactly the moment it matters.
    static func route(
        origin: CanvasOrigin?, owner: (CanvasOrigin) -> MailboxOwner?
    ) -> CanvasNoteRoute {
        guard let origin else { return .clipboard(.noOrigin) }
        guard let owner = owner(origin) else { return .clipboard(.originGone) }
        // The blessed path: a `Handle` read off the owner record, never assembled from a cwd and
        // a session id. `Handle`'s own header has the twenty-line version of why.
        return .mailbox(Handle(readingFrom: owner))
    }
}

// MARK: - CanvasNoteDelivery

/// What actually happened to a mark, and the sentence the pane shows for it.
///
/// A separate type from `CanvasNoteRoute` because a route is a decision and this is an outcome:
/// a route can be `.mailbox` and the delivery still fail, and the operator has to be able to tell
/// those apart — "sent to `sild-611a`" and "could not reach `sild-611a`" are opposite facts.
enum CanvasNoteDelivery: Equatable {
    case sent(Handle)
    case notSent(CanvasNoteRoute.Fallback)
    case failed(Handle, String)

    /// **Whether the note is also put on the operator's clipboard** (#303).
    ///
    /// **This reverses a decision that was taken deliberately, so it answers it rather than quietly
    /// dropping it.** `receipt(sidecar:)`'s header used to argue the unconditional copy: *"every
    /// case names the clipboard, because every case copies: the clipboard was the whole return path
    /// before #205 and removing it from the routed case would take a capability away from an
    /// operator who wants the note somewhere else as well."* Both of those facts are true; only the
    /// conclusion drawn from them is wrong. **The clipboard is the operator's, not helm's**, and
    /// replacing what is in it is a side effect they did not ask for — *they might also want the
    /// note elsewhere* is a reason to **offer** a copy, never a reason to take the clipboard every
    /// time. And on the routed path the copy bought nothing: the note is already twice recoverable,
    /// once in the agent's own mailbox and once in the sidecar on disk. What it cost was a paste
    /// buffer somebody was in the middle of using.
    ///
    /// **The three that keep it are keeping a return path, not a convenience.** With no agent, with
    /// an origin that is gone, or with a delivery that was attempted and failed, the clipboard is
    /// the only way the note reaches anybody at all — stranding it would be strictly worse than the
    /// pollution. That asymmetry is the whole rule: **copy when the copy is the delivery.**
    ///
    /// A property on the delivery rather than a branch at the call site, because it is a policy and
    /// there is more than one consumer of it — `Canvas.annotate` spends it and `receipt(sidecar:)`
    /// speaks it, and those two disagreeing is a receipt that names a clipboard nothing wrote to.
    var copiesToClipboard: Bool {
        switch self {
        // The agent has it. Anything further is helm helping itself to the pasteboard.
        case .sent: false
        case .notSent, .failed: true
        }
    }

    /// The receipt, naming the sidecar it was written to.
    ///
    /// **A case names the clipboard exactly when it copied to it** — `copiesToClipboard` is that
    /// rule and this is it said out loud, which since #303 is three cases of the four. Why it is
    /// said at all has not changed and is still right: the operator has to know their clipboard
    /// just changed under them. It stops applying to `sent` only because nothing changed under them
    /// there. `CanvasNoteRouteTests` pins the two against each other case by case, so a fifth case
    /// cannot copy silently or claim a copy it did not make.
    func receipt(sidecar: String) -> String {
        switch self {
        case let .sent(handle):
            "Written to \(sidecar) and sent to \(handle.value)"
        case .notSent(.noOrigin):
            "Written to \(sidecar) and copied — no agent pushed this canvas, so paste it to one"
        case .notSent(.originGone):
            "Written to \(sidecar) and copied — the agent that pushed this canvas is gone, "
                + "so paste it to another"
        case let .failed(handle, why):
            "Written to \(sidecar) and copied — could not reach \(handle.value): \(why). "
                + "Paste it instead"
        }
    }
}
