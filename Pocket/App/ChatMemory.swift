import Foundation
import PocketKit

/// What Pocket keeps per chat across launches: the unsent draft in its text field, and the last
/// transcript entry he had on screen (what unread compares a reply's index with). Keyed by
/// session id, in this phone's defaults.
@MainActor
final class ChatMemory: ObservableObject {
    @Published private(set) var drafts: [String: String]
    @Published private(set) var readThrough: [String: Int]
    /// What he sent that each chat's transcript does not hold yet: kept while the app runs, so
    /// leaving a chat and coming back still shows it.
    @Published private(set) var pending: [String: ChatPending] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        drafts = defaults.dictionary(forKey: "drafts") as? [String: String] ?? [:]
        readThrough = defaults.dictionary(forKey: "readThrough") as? [String: Int] ?? [:]
    }

    func draft(_ chat: String) -> String { drafts[chat] ?? "" }

    func sent(_ text: String, to chat: String, after: Int?, maybeSent: Bool) {
        pending[chat, default: ChatPending()].add(text, after: after, maybeSent: maybeSent)
    }

    /// The chat's transcript was rewritten: where its pending messages were sent from is gone.
    func rewrote(_ chat: String) { pending[chat]?.forgetPlaces() }

    /// The agent is working, or idle: a message an idle agent does not take says so.
    func agent(_ chat: String, busy: Bool) {
        guard var mine = pending[chat], !mine.messages.isEmpty else { return }
        mine.agent(busy: busy, at: Date())
        if mine != pending[chat] { pending[chat] = mine }
    }

    /// He put away a message that may not have gone.
    func dismiss(_ id: PendingMessage.ID, in chat: String) { pending[chat]?.remove(id) }

    /// The chat's transcript as read now: the messages it holds stop being pending.
    func reconcile(_ chat: String, with log: ChatLog) {
        guard var mine = pending[chat], !mine.messages.isEmpty else { return }
        mine.reconcile(log)
        if mine != pending[chat] { pending[chat] = mine }
    }

    func keep(_ text: String, for chat: String) {
        drafts[chat] = text.isEmpty ? nil : text
        defaults.set(drafts, forKey: "drafts")
    }

    /// He has the chat open with entry `index` of `total` on screen: everything up to it is read.
    /// A transcript now shorter than what he read was rewritten, and the mark starts over with it.
    func read(_ chat: String, through index: Int, of total: Int) {
        let read = readThrough[chat] ?? -1
        guard index > read || total <= read, index != read else { return }
        readThrough[chat] = index
        defaults.set(readThrough, forKey: "readThrough")
    }
}
