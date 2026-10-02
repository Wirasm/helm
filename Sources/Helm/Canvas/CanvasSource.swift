import CanvasKit
import Foundation
import HelmWire

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
