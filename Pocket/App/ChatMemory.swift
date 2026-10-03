import Foundation

/// What Pocket keeps per chat across launches: the unsent draft in its text field, and when he last
/// had it open (what unread compares a reply with). Keyed by session id, in this phone's defaults.
@MainActor
final class ChatMemory: ObservableObject {
    @Published private(set) var drafts: [String: String]
    @Published private(set) var opened: [String: UInt64]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        drafts = defaults.dictionary(forKey: "drafts") as? [String: String] ?? [:]
        opened = (defaults.dictionary(forKey: "opened") as? [String: NSNumber] ?? [:])
            .mapValues(\.uint64Value)
    }

    func draft(_ chat: String) -> String { drafts[chat] ?? "" }

    func keep(_ text: String, for chat: String) {
        drafts[chat] = text.isEmpty ? nil : text
        defaults.set(drafts, forKey: "drafts")
    }

    /// He has the chat open now: every reply until this moment is read.
    func read(_ chat: String) {
        opened[chat] = UInt64(Date().timeIntervalSince1970 * 1000)
        defaults.set(opened.mapValues { NSNumber(value: $0) }, forKey: "opened")
    }
}
