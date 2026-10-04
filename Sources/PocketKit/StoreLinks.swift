import Foundation
import HelmWire

/// Document links resolved against the stores and home named by benchd, never the phone's disk.
package struct StoreLinks: Equatable, Sendable {
    private let roots: [String]
    private let home: String?

    package init(stores: [BenchPrpStore] = [], home: String? = nil) {
        roots = stores.compactMap { FilesystemPath.standardized($0.dir) }
        self.home = home
    }

    package static let scheme = "pocket-page"

    package func page(_ token: String) -> PocketPage? {
        let expanded = token.hasPrefix("~/") ? home.map { $0 + token.dropFirst() } : token
        guard let expanded, let path = FilesystemPath.standardized(expanded),
            path.lowercased().hasSuffix(".md") || path.lowercased().hasSuffix(".html"),
            let root = roots.first(where: { path.hasPrefix($0 + "/") })
        else { return nil }
        let relative = String(path.dropFirst(root.count + 1))
        return PocketPage(
            path: path, title: (relative as NSString).deletingPathExtension, modifiedMs: 0,
            store: root)
    }

    package func page(at url: URL) -> PocketPage? {
        guard url.scheme == Self.scheme, url.host == nil else { return nil }
        return page(url.path)
    }

    /// Keep inline styling and web links. A filesystem destination outside a named store loses
    /// its link attribute; explicit path tokens in the displayed text get document links too.
    package func linking(_ text: AttributedString) -> AttributedString {
        var out = text
        for run in text.runs {
            guard let url = run.link,
                url.scheme == nil || url.scheme == "file" || url.scheme == Self.scheme
            else { continue }
            out[run.range].link = Self.path(url).flatMap(page).flatMap(Self.url)
        }
        let plain = String(text.characters)
        // This is a path-token grammar, not interpretation of the surrounding message.
        let pattern =
            #"(?<![\w/~:.])(?:~/|/)[^\s`"'<>\[\]()]+\.(?:md|html)(?=$|[\s`"'<>\[\]()]|[.,;:!?](?=$|[\s`"'<>\[\]()]))"#
        guard let tokens = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return out }
        for token in tokens.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let range = Range(token.range, in: plain),
                let start = AttributedString.Index(range.lowerBound, within: out),
                let end = AttributedString.Index(range.upperBound, within: out),
                out[start..<end].runs.allSatisfy({ $0.link == nil }),
                let page = page(String(plain[range]))
            else { continue }
            out[start..<end].link = Self.url(page)
        }
        return out
    }

    private static func path(_ url: URL) -> String? {
        guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        return url.path
    }

    private static func url(_ page: PocketPage) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.path = page.path
        return parts.url
    }
}
