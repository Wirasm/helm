import Foundation

// MARK: - CanvasSource

/// What a canvas pane is showing, as a value the workbench can persist. CONTEXT.md:
/// the canvas is *modular by source* — a file an agent or the operator opened, or a
/// URL.
///
/// A sum rather than two optionals, because a canvas showing both a file and a URL is
/// not a state that exists — and because the difference has to survive the persistence
/// seam. `WorkspaceContext.openArtifactPath` was a **file** path, so #38 deliberately
/// persisted nothing for a URL canvas rather than write `url.path` (empty, or a stray
/// `/segment`) into a field read back through `URL(fileURLWithPath:)`. This type is what
/// retires that field: a bench pane carries its own source, so a URL canvas comes back.
///
/// **An address, not a document.** It used to carry `CanvasModel.Document` /
/// `CanvasModel.Page` — the rendered content, the file watcher's generation counter, the
/// last load failure — which is live state that cannot be `Codable` and should not be. The
/// model keeps all of that as `CanvasModel.Showing`; what a pane persists is only enough to
/// re-open the same thing.
enum CanvasSource: Equatable {
    /// A file on disk. **Always standardized** — build one with `file(_:)` rather than
    /// naming the case, or `Workbench.pane(showing:)` silently stops matching: it compares
    /// sources by value, so `/a/b.md` and `/a/./b.md` would be two different canvases and
    /// ⌘-clicking the same link twice would open two copies.
    case file(path: String)
    /// A page the canvas navigated to.
    case url(URL)
    /// A canvas with nothing in it yet — what ⌘L opens before an address is committed.
    /// Persisted as itself so the empty pane comes back rather than vanishing.
    case empty

    /// The only way to build a file source. See `.file(path:)`.
    static func file(_ url: URL) -> CanvasSource {
        .file(path: standardized(url.path))
    }

    /// One place, so the decoder and the constructor cannot disagree about what
    /// "the same file" means.
    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The file this source names, for the model that has to load it.
    var fileURL: URL? {
        if case let .file(path) = self { URL(fileURLWithPath: path) } else { nil }
    }
}

// MARK: - Codable

/// Hand-written with a string discriminator. The synthesized shape is
/// `{"file":{"path":"…"}}` for a payload-labelled case and `{"url":{"_0":"…"}}` for an
/// unlabelled one — positional `_0` keys that break on any reordering and are unreadable
/// in the stored blob. A pane's source is something an operator may well have to look at
/// in `defaults read`, so it is spelled out.
extension CanvasSource: Codable {
    private enum CodingKeys: String, CodingKey { case kind, path, address }
    private enum Kind: String, Codable { case file, url, empty }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .file:
            self = .file(path: Self.standardized(try container.decode(String.self, forKey: .path)))
        case .url:
            self = .url(try container.decode(URL.self, forKey: .address))
        case .empty:
            self = .empty
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .file(path):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(path, forKey: .path)
        case let .url(url):
            try container.encode(Kind.url, forKey: .kind)
            try container.encode(url, forKey: .address)
        case .empty:
            try container.encode(Kind.empty, forKey: .kind)
        }
    }
}
