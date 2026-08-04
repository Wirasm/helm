import Foundation

// MARK: - StandardizedPath

/// A file path that has already been standardized, and cannot be anything else.
///
/// `Workbench.pane(showing:)` compares sources **by value**, so "is this file already
/// open?" is a string compare — and it only answers correctly if every path was
/// standardized on the way in. That used to be a doc comment asking callers to prefer
/// `CanvasSource.file(_:)` over naming the case, which is a convention rather than a gate:
/// `.file(path: "/a/./b.md")` compiled from anywhere in the module, and `WorkbenchTests`'
/// own helper already took that shortcut (#88).
///
/// The explicit `init` is the mechanism — it suppresses the synthesized memberwise one, so
/// there is no `StandardizedPath(value:)` and no way to hold a path that skipped
/// `standardizedFileURL`. Every route in standardizes.
struct StandardizedPath: Equatable, Hashable, Codable {
    let value: String

    init(_ url: URL) {
        value = URL(fileURLWithPath: url.path).standardizedFileURL.path
    }

    init(_ path: String) {
        self.init(URL(fileURLWithPath: path))
    }

    /// Decoding is a route in like any other, so it standardizes too — one place, so the
    /// decoder and the constructor cannot disagree about what "the same file" means.
    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

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
    /// A file on disk. The payload type carries the guarantee: a `StandardizedPath` cannot
    /// be built unstandardized, so `Workbench.pane(showing:)`'s by-value compare cannot
    /// silently stop matching and ⌘-clicking the same link twice stays one canvas.
    case file(path: StandardizedPath)
    /// A page the canvas navigated to.
    case url(URL)
    /// A canvas with nothing in it yet — what ⌘L opens before an address is committed.
    /// Persisted as itself so the empty pane comes back rather than vanishing.
    case empty

    static func file(_ url: URL) -> CanvasSource {
        .file(path: StandardizedPath(url))
    }

    static func file(_ path: String) -> CanvasSource {
        .file(path: StandardizedPath(path))
    }

    /// The file this source names, for the model that has to load it.
    var fileURL: URL? {
        if case let .file(path) = self { URL(fileURLWithPath: path.value) } else { nil }
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
            // StandardizedPath standardizes on decode, so a hand-edited defaults blob
            // carrying `/a/./b.md` comes back as the same source as `/a/b.md`.
            self = .file(path: try container.decode(StandardizedPath.self, forKey: .path))
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
