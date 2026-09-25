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

/// What a canvas pane is showing, as a value the workbench can persist: a file an agent or
/// the operator opened.
///
/// **One case, and still an enum with a `kind` on the wire.** It had three — a file, a URL
/// and an empty ⌘L canvas — until #376 removed the URL canvas; web pages are the shared
/// browser's now. A payload that can grow a second kind keeps its discriminator (AGENTS.md),
/// and it is also what makes a stored `url` or `empty` source fail to decode, so `Slot` drops
/// that pane rather than guessing at it.
///
/// **An address, not a document.** The rendered content and the file watcher's generation
/// counter are live state that cannot be `Codable` and should not be. The model keeps those as
/// `CanvasModel.Document`; what a pane persists is only enough to re-open the same thing.
enum CanvasSource: Equatable {
    /// A file on disk. The payload type carries the guarantee: a `StandardizedPath` cannot
    /// be built unstandardized, so `Workbench.pane(showing:)`'s by-value compare cannot
    /// silently stop matching and ⌘-clicking the same link twice stays one canvas.
    case file(path: StandardizedPath)

    static func file(_ url: URL) -> CanvasSource {
        .file(path: StandardizedPath(url))
    }

    static func file(_ path: String) -> CanvasSource {
        .file(path: StandardizedPath(path))
    }

    /// The file this source names, for the model that has to load it.
    var fileURL: URL {
        switch self {
        case let .file(path): URL(fileURLWithPath: path.value)
        }
    }
}

// MARK: - Codable

/// Hand-written with a string discriminator. The synthesized shape is
/// `{"file":{"path":"…"}}` — no `kind`, and unreadable in the stored blob. A pane's source is something an operator may well have to look at
/// in `defaults read`, so it is spelled out.
extension CanvasSource: Codable {
    private enum CodingKeys: String, CodingKey { case kind, path }
    private enum Kind: String, Codable { case file }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .file:
            // StandardizedPath standardizes on decode, so a hand-edited defaults blob
            // carrying `/a/./b.md` comes back as the same source as `/a/b.md`.
            self = .file(path: try container.decode(StandardizedPath.self, forKey: .path))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .file(path):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}
