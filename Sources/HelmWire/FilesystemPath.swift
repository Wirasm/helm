import Foundation

/// Tilde-expanded, no trailing slash — the one normalisation both `Workspace` (a helm sidebar
/// identity) and `SpoolPolicy` (a spawn's `cwd`) need, kept in one place rather than two.
///
/// **Why this lives here and `Workspace` does not.** `SpoolRequest.swift` needs to turn a
/// caller-supplied `cwd` into the same canonical form `Workspace` uses for folder identity, so
/// the two must never drift — a spawn accepted under one spelling of a path and a workspace
/// opened under another would be two different folders wearing one name. `Workspace` itself is
/// a sidebar-facing value (`Hashable`, `Identifiable`, persisted through `UserDefaults`) with no
/// business in a library that exists to hold the spool's wire format, so rather than moving it
/// whole or restating its three-line body a second time — the exact "typed on one side, spelled
/// out on the other" shape `AGENTS.md`'s architecture section warns against —
/// `Workspace.normalized` delegates to this instead.
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
