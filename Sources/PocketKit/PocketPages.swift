import Foundation
import HelmWire

/// A plan or review page in a workspace's prp store: an `.html` file benchd lists
/// (`prp/artifacts`), rendered as helm renders a canvas (`CanvasSchemeHandler`).
package struct PocketPage: Equatable, Sendable, Identifiable {
    package var path: String
    /// Under its store: `plans/foo.plan`, without `.html`.
    package var title: String
    package var modifiedMs: UInt64

    package var id: String { path }
}

package enum PocketPages {
    /// Every store's `.html` files once, newest first. Each listing is one store's, as
    /// `prp/artifacts` answers it.
    package static func pages(files listings: [[BenchPrpArtifact]]) -> [PocketPage] {
        var seen = Set<String>()
        return listings.joined()
            .filter { $0.path.lowercased().hasSuffix(".html") && seen.insert($0.path).inserted }
            .sorted { $0.modifiedMs > $1.modifiedMs }
            .map {
                PocketPage(
                    path: $0.path, title: String($0.relative.dropLast(".html".count)),
                    modifiedMs: $0.modifiedMs)
            }
    }
}

/// The operator's reply to a page, as Pocket writes it: an entry in the page's live file
/// (`<stem>.data.json`, `BenchLiveFile`), which benchd mails to the agent that opened the page.
package enum PocketReply {
    /// The live file with `text` appended to its `replies`, every other key kept, written as a
    /// page writes it (`CanvasDataWrite`: sorted, pretty, a trailing newline). nil when the file
    /// is there and is not a JSON object, or keeps `replies` as something other than a list: it
    /// is the page's, and Pocket does not write over it.
    package static func adding(_ text: String, at date: Date, to existing: Data?) -> String? {
        var object: [String: Any] = [:]
        if let existing {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any]
            else { return nil }
            object = parsed
        }
        if object["replies"] != nil, !(object["replies"] is [Any]) { return nil }
        var replies = object["replies"] as? [Any] ?? []
        let at = ISO8601DateFormatter().string(from: date)
        replies.append(["from": "pocket", "text": text, "at": at])
        object["replies"] = replies
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
