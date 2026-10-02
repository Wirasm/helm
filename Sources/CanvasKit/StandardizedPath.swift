import Foundation
import HelmWire

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
/// standardizing. Every route in standardizes.
///
/// **benchd's rule, not Foundation's** (`FilesystemPath.standardized`, held to
/// `bench_doc::StandardPath` by `daemon/fixtures/standard-path.json`). The path is compared
/// against benchd's too: its document names the canvas, and its live-file mail finds a canvas
/// by the path helm writes. `standardizedFileURL` dropped `/private` from `/private/tmp/…`, so
/// the two named one file two ways and the opener was never mailed.
package struct StandardizedPath: Equatable, Hashable, Codable {
    package let value: String

    package init(_ url: URL) {
        // A relative path is resolved against the working directory first, as it always was;
        // `URL(fileURLWithPath:)` makes it absolute, so `standardized` never refuses it.
        let absolute = URL(fileURLWithPath: url.path).path
        value = FilesystemPath.standardized(absolute) ?? absolute
    }

    package init(_ path: String) {
        self.init(URL(fileURLWithPath: path))
    }

    /// Decoding is a route in like any other, so it standardizes too — one place, so the
    /// decoder and the constructor cannot disagree about what "the same file" means.
    package init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
