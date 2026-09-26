import Foundation

/// Tilde-expanded, no trailing slash — the normalisation a workspace's folder identity uses
/// (`WorkspacePath`). A path's spelling is display noise, and two spellings of one folder must
/// never be two workspaces.
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
}
