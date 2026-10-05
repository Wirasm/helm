import CanvasKit
import Foundation
import HelmWire

/// A document in a named prp store: an `.html` page benchd lists (`prp/artifacts`) or a
/// markdown/HTML document linked from chat. HTML renders as helm renders a canvas.
package struct PocketPage: Hashable, Sendable, Identifiable {
    package var path: String
    /// Under its store: `plans/foo.plan`, without its document extension.
    package var title: String
    package var modifiedMs: UInt64
    /// The named store the document is confined to when benchd reads it.
    package var store: String

    package var id: String { path }
}

/// One workspace on the pages tab: the Markdown and HTML documents of its prp store, last edited first.
package struct PocketPageSection: Equatable, Sendable, Identifiable {
    /// The workspace's folder.
    package var path: String
    package var pages: [PocketPage]

    package var id: String { path }
    package var name: String { URL(fileURLWithPath: path).lastPathComponent }

    /// Only the pages whose title has `query` (any case); nil when none does. An empty query
    /// shows the twenty newest; searching always examines the full inventory.
    package func matching(_ query: String) -> PocketPageSection? {
        let words = query.trimmingCharacters(in: .whitespaces)
        let kept =
            words.isEmpty
            ? Array(pages.prefix(20))
            : pages.filter { $0.title.localizedCaseInsensitiveContains(words) }
        return kept.isEmpty ? nil : PocketPageSection(path: path, pages: kept)
    }
}

package enum PocketPages {
    /// Each workspace's store as a section, the one edited last first, its pages newest first.
    /// `listings` is each workspace with what `prp/artifacts` answered for its store, in the
    /// document's order; a store two workspaces share is listed under the first. A page is in one
    /// section, and a workspace with no page has none.
    package static func sections(
        _ listings: [(workspace: String, store: String, files: [BenchPrpArtifact])]
    ) -> [PocketPageSection] {
        var seen = Set<String>()
        return listings.compactMap { workspace, store, files in
            let pages =
                files
                .filter {
                    let ext = ($0.path as NSString).pathExtension.lowercased()
                    return (ext == "md" || ext == "html") && seen.insert($0.path).inserted
                }
                .sorted { $0.modifiedMs > $1.modifiedMs }
                .map {
                    PocketPage(
                        path: $0.path, title: ($0.relative as NSString).deletingPathExtension,
                        modifiedMs: $0.modifiedMs, store: store)
                }
            return pages.isEmpty ? nil : PocketPageSection(path: workspace, pages: pages)
        }
        .sorted { $0.pages[0].modifiedMs > $1.pages[0].modifiedMs }
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
        return CanvasDataWrite.text(of: object)
    }
}
