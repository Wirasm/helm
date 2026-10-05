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
}

/// One chat's pending messages, each taken away once by the prompt that arrives for it.
package struct ChatPending: Equatable, Sendable {
    package private(set) var messages: [PendingMessage] = []
    /// Transcript prompts already matched to a message: one prompt answers for one message.
    private var claimed: Set<Int> = []

    package init() {}

    package mutating func add(_ text: String, after: Int?, maybeSent: Bool = false) {
        messages.append(PendingMessage(text: text, after: after, maybeSent: maybeSent))
    }

    /// Takes away each message whose prompt the transcript now holds: his own (not another
    /// session's), with the same text, after the entry he had when he sent it, not already
    /// matched to another message.
    package mutating func reconcile(_ log: ChatLog) {
        for entry in log.entries where entry.kind == .user && entry.from == nil {
            guard !claimed.contains(entry.index) else { continue }
            let text = Self.normalized(entry.text)
            guard
                let at = messages.firstIndex(where: {
                    Self.normalized($0.text) == text && entry.index > ($0.after ?? -1)
                })
            else { continue }
            messages.remove(at: at)
            claimed.insert(entry.index)
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
