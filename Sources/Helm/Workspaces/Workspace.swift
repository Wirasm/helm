import Foundation
import HelmWire

/// A folder helm has open — the operating context that replaced the engine's
/// registry `project`. Identity is the PATH, deliberately: a main checkout and one
/// of its worktrees are two workspaces, which a registry keyed by unique name could
/// never express. Nothing is registered anywhere; opening the folder is the whole
/// ceremony, and closing one is a purely local list removal.
struct Workspace: Hashable, Identifiable, Codable {
    /// Absolute, tilde-expanded, no trailing slash. This is the origin every other
    /// `workspacePath` in the app descends from (`AGENTS.md`) — `WorkspacePath`'s own `init`
    /// calls `HelmWire.FilesystemPath.normalized` directly, the same function `Self.normalized`
    /// below delegates to, so both routes in end up normalized the same way. See
    /// `WorkspacePath`'s header for why that is a direct call and not a call through here.
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
    /// **Kept as a free `String -> String` function** for `DefaultsDomain`'s legacy-domain
    /// migration, which normalizes a persisted context key and is out of scope for both #221
    /// and #223. `WorkspacePath.init` does **not** go through this any more — see its header —
    /// so this is no longer "the" normalizer everything else hangs off, just one more direct
    /// caller of the one below it. Retiring it entirely would mean `DefaultsDomain` importing
    /// `HelmWire` for a single call in a file that otherwise has no business knowing the spool
    /// exists; keeping this one-line wrapper here reads better than that import would.
    ///
    /// **The body delegates to `HelmWire.FilesystemPath` (#221) rather than restating its
    /// three lines** — a library both sides compile against, not a second copy that can drift
    /// the way `tools/*.swift` used to. `WorkspacePath.init` and `SpoolPolicy.accept` both call
    /// `FilesystemPath.normalized` directly now, as siblings of this function rather than
    /// through it; `WorkspacePathSpoolAgreementTests` is what proves those two independent call
    /// sites still agree, since nothing in the type system does.
    static func normalized(_ path: String) -> String {
        FilesystemPath.normalized(path)
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
