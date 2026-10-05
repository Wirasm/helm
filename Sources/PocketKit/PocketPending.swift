import Foundation
import HelmWire

/// A message he sent that the transcript does not hold yet. claude, codex and pi all queue a
/// message typed while they work and write it to the transcript only when they take it, so the
/// chat shows it from the moment it is sent until the transcript has it.
package struct PendingMessage: Equatable, Sendable, Identifiable {
    package let id = UUID()
    package var text: String
    /// The newest transcript entry when it was sent: only a prompt after it can be this message.
    package var after: Int?
    /// benchd did not answer the send, so it may not have reached the agent.
    package var maybeSent: Bool
    /// The agent sat idle for `ChatPending.landing` without the transcript having it: it did not
    /// land, and waiting longer will not change that.
    package var notTaken = false

    /// He can put it away: it may not have gone, or the agent did not take it.
    package var canPutAway: Bool { maybeSent || notTaken }
}

/// One chat's pending messages, each taken away once by the prompt that arrives for it.
package struct ChatPending: Equatable, Sendable {
    package private(set) var messages: [PendingMessage] = []
    /// Transcript prompts already matched to a message: one prompt answers for one message.
    private var claimed: Set<Int> = []
    /// Since when the agent has been idle; nil while it works.
    private var idleSince: Date?

    package init() {}

    /// A send starts the idle clock over: the agent being idle before it does not count.
    package mutating func add(_ text: String, after: Int?, maybeSent: Bool = false) {
        messages.append(PendingMessage(text: text, after: after, maybeSent: maybeSent))
        idleSince = nil
    }

    /// How long an agent may sit idle with a message it has not taken. claude, codex and pi take
    /// a queued message the moment they finish a turn, so this only has to outlast the
    /// transcript's next read and benchd's report of the agent's state.
    package static let landing: TimeInterval = 20

    /// The agent is working, or idle, at `now`. A message still waiting once the agent has been
    /// idle for `landing` since the last send did not land: its text may sit in the agent's
    /// input, or have gone to a question the agent was asking.
    package mutating func agent(busy: Bool, at now: Date) {
        guard !busy else {
            idleSince = nil
            return
        }
        let idle = idleSince ?? now
        idleSince = idle
        guard now.timeIntervalSince(idle) >= Self.landing else { return }
        for i in messages.indices { messages[i].notTaken = true }
    }

    /// Takes away each message whose prompt the transcript now holds: his own (not another
    /// session's), with the same text or holding it as whole lines (a paste after what he had
    /// typed in the pane), after the entry he had when he sent it, not already matched to another
    /// message.
    package mutating func reconcile(_ log: ChatLog) {
        for entry in log.entries where entry.kind == .user && entry.from == nil {
            guard !claimed.contains(entry.index) else { continue }
            let text = Self.normalized(entry.text)
            guard
                let at = messages.firstIndex(where: {
                    Self.holds(text, Self.normalized($0.text)) && entry.index > ($0.after ?? -1)
                })
            else { continue }
            messages.remove(at: at)
            claimed.insert(entry.index)
        }
        // Only a waiting message can be matched: with none, what was matched is not needed.
        if messages.isEmpty { claimed.removeAll() }
    }

    /// The transcript was rewritten and numbers its entries again (`ChatLog.resets`): the
    /// matched entries and where each message was sent from no longer mean anything.
    package mutating func forgetPlaces() {
        claimed.removeAll()
        for i in messages.indices { messages[i].after = nil }
    }

    /// The entry the oldest waiting message was sent after, when `log` starts later than it:
    /// its prompt may be in what the chat has not read, so the chat reads from there. nil when
    /// the log covers every waiting message, or one was sent with nothing read yet.
    package func unseen(in log: ChatLog) -> Int? {
        guard let oldest = log.oldest,
            let from = messages.compactMap(\.after).min(),
            from + 1 < oldest
        else { return nil }
        return from
    }

    package mutating func remove(_ id: PendingMessage.ID) {
        messages.removeAll { $0.id == id }
        if messages.isEmpty { claimed.removeAll() }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `prompt` is `message`, or holds it as whole lines.
    private static func holds(_ prompt: String, _ message: String) -> Bool {
        "\n\(prompt)\n".contains("\n\(message)\n")
    }
}
