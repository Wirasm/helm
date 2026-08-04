import Foundation

/// Which files a canvas may read: the artifact's own directory, and nothing else.
///
/// This is the boundary `loadFileURL(_:allowingReadAccessTo:)` used to enforce, now that
/// helm serves artifacts itself. A page's relative references (`./diagram.css`,
/// `img/x.png`) must resolve to siblings; nothing may resolve outside.
///
/// **Pure on purpose**, in the style of `CanvasURLPolicy` and `CanvasAddress`: the decision
/// lives where `swift test` reaches it, rather than inside a `WKURLSchemeHandler` where
/// exercising it would need a live `WKURLSchemeTask`. That is not a tidiness preference —
/// the first version of this check was a private method on the handler, and the symlink
/// case below went unnoticed precisely because there was nowhere to write the test.
///
/// It touches the filesystem, which a policy usually should not. That is the whole point
/// here: **a containment check that reasons only about strings is not a containment
/// check.** `standardizedFileURL` collapses `..` lexically and never asks the filesystem
/// anything, so a symlink sitting inside the directory and pointing out of it produces a
/// candidate whose *string* is safely inside — and `Data(contentsOf:)` then follows it.
enum CanvasFileBoundary {
    /// The file a request resolves to, or nil if it escapes `directory`.
    ///
    /// Both sides are canonicalized — `..` collapsed *and* symlinks followed — before they
    /// are compared, so containment is decided about the file that would actually be read
    /// rather than about the text of the request.
    static func resolve(request path: String, inDirectory directory: URL) -> URL? {
        let relative = String(path.drop(while: { $0 == "/" }))
        guard !relative.isEmpty else { return nil }

        let candidate = canonical(directory.appendingPathComponent(relative))
        let root = canonical(directory)

        // The trailing slash matters: without it, `/artifacts/plan` would contain
        // `/artifacts/plan-evil/secret.txt` by simple prefix.
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }

    /// `..` collapsed, then symlinks followed. Both are needed and neither implies the
    /// other. Applied to the root as well as the candidate, because on macOS the root may
    /// itself sit under a symlink (`/tmp` → `/private/tmp`) and comparing a resolved
    /// candidate against an unresolved root would then refuse every legitimate sibling.
    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
