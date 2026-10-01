import Foundation

/// A path's spelling is display noise, and two spellings of one folder must never be two
/// workspaces, nor two of one file two canvases. `normalized` is a workspace's folder identity
/// (`WorkspacePath`); `standardized` is a canvas file's (`StandardizedPath`), benchd's rule.
/// Neither resolves a symlink.
package enum FilesystemPath {
    /// A trailing slash and a leading `~` are display noise, not identity: two values differing
    /// only by one would be two sidebar rows, or two spawns, for one folder. Symlinks are
    /// deliberately NOT resolved — the path the caller named is the path helm shows and spawns
    /// against.
    package static func normalized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var trimmed = Substring(expanded)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    /// One spelling of an absolute path, benchd's `bench_doc::StandardPath` rule: empty and `.`
    /// components dropped, `..` collapsed lexically, no trailing slash. `nil` for a relative path,
    /// which benchd refuses too. `daemon/fixtures/standard-path.json` holds both copies to one
    /// table.
    ///
    /// **Lexical, never the filesystem's.** `URL.standardizedFileURL` drops a leading `/private`
    /// when the shorter path exists, so a canvas benchd's document holds as
    /// `/private/tmp/review.html` became `/tmp/review.html` in helm, and the live file helm wrote
    /// matched no canvas benchd knew: its opener was never mailed.
    package static func standardized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
