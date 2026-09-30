import Foundation
import HelmWire

// MARK: - CanvasOrigin

/// The terminal pane whose agent put a canvas on the bench (#205).
///
/// **benchd's record, read off the document** (`Pane.opener`, #532). benchd writes it from an
/// agent's `pane/open`, whether the canvas was new or already open, so the newest opener is the
/// one a mark reaches. Being in the document is what lets the route survive a helm relaunch: every
/// terminal pane is a benchd session (M5b), so the agent that opened the canvas is still in its
/// pane after helm comes back.
///
/// **A newtype over the pane id rather than a bare `UUID`**: the canvas pane and the terminal
/// pane are both `UUID`s, and this says which one it is.
///
/// **Resolved late.** What is recorded is which pane, not which pid or handle: a handle read at
/// open time would be stale the moment that agent restarted in the same pane, and stale silently.
/// Asking benchd who is in the pane *now* (`mail/who`), when the mark is made, cannot be.
struct CanvasOrigin: Equatable, Hashable {
    /// The terminal pane, which for a terminal *is* its `TerminalSession.ID` (`Pane`'s header).
    let terminal: Pane.ID
}

// MARK: - CanvasNoteRoute

/// Where an operator's mark goes once it is written down.
///
/// **Pure, and the whole decision.** #205's acceptance asks for a test over the routing decision
/// rather than over a note posted by hand, and this is the shape that makes one possible: the
/// lookup is a closure, so the rule is a test that asks no daemon.
enum CanvasNoteRoute: Equatable {
    /// The agent that pushed this canvas, still reachable.
    case mailbox(Handle)
    /// Nobody to send to. The note is on the clipboard, exactly as before this existed, and the
    /// pane says which of these it was — **a silent no-op here is the worst outcome**, because
    /// the operator believes the note was sent.
    case clipboard(Fallback)

    enum Fallback: Equatable {
        /// No agent opened this canvas: the operator opened it himself.
        case noOrigin
        /// An agent pushed it, and benchd knows no mailbox in that pane — the pane was closed, the
        /// session ended, or its harness does not report to benchd.
        case originGone
    }

    /// **`origin == nil` and `handle == nil` are different answers, and the operator is told
    /// which.** They read identically from the outside — no mail either way — and collapsing them
    /// would leave "why did nothing send?" unanswerable at exactly the moment it matters.
    static func route(
        origin: CanvasOrigin?, handle: (CanvasOrigin) -> Handle?
    ) -> CanvasNoteRoute {
        guard let origin else { return .clipboard(.noOrigin) }
        guard let handle = handle(origin) else { return .clipboard(.originGone) }
        return .mailbox(handle)
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
