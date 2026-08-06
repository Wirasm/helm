import Foundation

/// A folder helm has open — the operating context that replaced the engine's
/// registry `project`. Identity is the PATH, deliberately: a main checkout and one
/// of its worktrees are two workspaces, which a registry keyed by unique name could
/// never express. Nothing is registered anywhere; opening the folder is the whole
/// ceremony, and closing one is a purely local list removal.
struct Workspace: Hashable, Identifiable, Codable {
    /// Absolute, tilde-expanded, no trailing slash. This is the origin every other
    /// `workspacePath` in the app descends from (`AGENTS.md`) — `WorkspacePath`'s own `init`
    /// calls `Self.normalized` below, so both routes in end up normalized the same way.
    let path: WorkspacePath

    var id: WorkspacePath { path }

    /// The folder's basename — what the sidebar row shows in bold.
    var name: String {
        let last = (path.value as NSString).lastPathComponent
        return last.isEmpty ? path.value : last
    }

    init(path: String) {
        self.path = WorkspacePath(path)
    }

    init(url: URL) {
        self.path = WorkspacePath(url)
    }

    /// A trailing slash and a leading `~` are display noise, not identity: two
    /// values differing only by one would be two sidebar rows for one folder.
    /// Symlinks are deliberately NOT resolved here — the path the operator chose is
    /// the path helm shows and filters on; only store resolution needs the real one.
    ///
    /// **Kept as a free `String -> String` function rather than folded entirely into
    /// `WorkspacePath`.** `Spool/SpoolRequest.swift` and `DefaultsDomain`'s legacy-domain
    /// migration both call this directly, and both are out of scope for #223 (#221 owns the
    /// former). `WorkspacePath.init` calls this same function, so there is exactly one
    /// normalizer, not two that can drift apart — do not reimplement this in `WorkspacePath`.
    static func normalized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var trimmed = Substring(expanded)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    // Coded as a bare path string, so the persisted blob is a plain ["/a", "/b"] —
    // and, unlike the synthesized conformance, decoding runs through the normaliser.
    init(from decoder: any Decoder) throws {
        self.init(path: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }
}
