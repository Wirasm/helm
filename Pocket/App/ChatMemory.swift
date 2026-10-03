import Foundation

/// What Pocket keeps per chat across launches: the unsent draft in its text field, and the last
/// transcript entry he had on screen (what unread compares a reply's index with). Keyed by
/// session id, in this phone's defaults.
@MainActor
final class ChatMemory: ObservableObject {
    @Published private(set) var drafts: [String: String]
    @Published private(set) var readThrough: [String: Int]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        drafts = defaults.dictionary(forKey: "drafts") as? [String: String] ?? [:]
        readThrough = defaults.dictionary(forKey: "readThrough") as? [String: Int] ?? [:]
    }

    func draft(_ chat: String) -> String { drafts[chat] ?? "" }

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
