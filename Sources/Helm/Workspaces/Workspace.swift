import Foundation

/// A folder helm has open — the operating context that replaced the engine's
/// registry `project`. Identity is the PATH, deliberately: a main checkout and one
/// of its worktrees are two workspaces, which a registry keyed by unique name could
/// never express. Nothing is registered anywhere; opening the folder is the whole
/// ceremony, and closing one is a purely local list removal.
struct Workspace: Hashable, Identifiable, Codable {
    /// Absolute, tilde-expanded, no trailing slash.
    let path: String

    var id: String { path }

    /// The folder's basename — what the sidebar row shows in bold.
    var name: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    init(path: String) {
        self.path = Self.normalized(path)
    }

    init(url: URL) {
        self.init(path: url.path)
    }

    /// A trailing slash and a leading `~` are display noise, not identity: two
    /// values differing only by one would be two sidebar rows for one folder.
    /// Symlinks are deliberately NOT resolved here — the path the operator chose is
    /// the path helm shows and filters on; only store resolution needs the real one.
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
