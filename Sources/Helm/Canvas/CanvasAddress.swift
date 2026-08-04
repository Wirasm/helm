import CryptoKit
import Foundation

/// The address a file canvas is served on, and the rule for whether a bridge message
/// really came from it.
///
/// **Addressing is the feature, not plumbing.** A canvas had no name an agent could mean:
/// `loadHTMLString(baseURL: nil)` gives a page no origin at all and `loadFileURL` gives it
/// an empty one, so every canvas looked identical to `WKFrameInfo.securityOrigin` and helm
/// could not say which one a message came from. That is precisely the omission behind
/// ChatGPT's `update_textdoc`, which names no document and consequently reports success on
/// a document it did not edit.
///
/// Serving each artifact from its **own synthetic host** fixes it: a custom-scheme page
/// gets a real tuple origin (verified on macOS 26.5.1 — `window.origin` is the scheme and
/// host, `isSecureContext` is true), so the origin becomes a genuine key rather than an
/// empty string.
///
/// Pure on purpose, in the style of `CanvasURLPolicy` and `CanvasBridgePolicy`: a
/// `WKSecurityOrigin` cannot be built in a test, so the decision lives here where
/// `swift test` reaches it and the webview is left with nothing but plumbing.
enum CanvasAddress {
    /// helm's own scheme. Not one WebKit handles natively — registering a handler for
    /// `file:`/`http:`/`about:` and friends throws — and not one any other app claims.
    static let scheme = "helm-canvas"

    /// The host this artifact is served on: stable for a path, distinct between paths.
    ///
    /// A hash rather than the path itself, because a host has a much smaller alphabet than
    /// a POSIX path — spaces, slashes, `~` and non-ASCII are all ordinary in a filename and
    /// none may appear in a host. Hex is always a legal host and always lowercase, so the
    /// case-insensitivity of host comparison cannot surprise anyone.
    ///
    /// It takes a `StandardizedPath` rather than a `String` so the identity the origin
    /// carries is the same identity `Workbench.pane(showing:)` compares by (#88) — two
    /// spellings of one file cannot become two hosts.
    static func host(for path: StandardizedPath) -> String {
        let digest = SHA256.hash(data: Data(path.value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Where the artifact itself is served. The last path component is kept so a page's
    /// own relative references (`./diagram.css`, `img/x.png`) resolve to sibling paths on
    /// the same host, which is what makes an `.html` artifact keep working.
    static func url(for path: StandardizedPath) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host(for: path)
        components.path = "/" + (path.value as NSString).lastPathComponent
        return components.url
    }

    /// Whether a message that arrived over the bridge may be attributed to `expectedHost`.
    ///
    /// Three independent conditions, all required:
    ///
    /// - **Main frame only.** `forMainFrameOnly: true` scopes helm's injected *script*, not
    ///   the *handler* — a cross-origin iframe does reach the handler today, confirmed
    ///   (`mainFrame=false origin=helmtest2://evil`). So the frame has to be checked here.
    /// - **Our scheme.** `passesSameOriginCheck` is not a trust check and
    ///   `WebKitNamespace` is per-window, so "it reached us" says nothing about who sent it.
    /// - **The expected host.** This is the actual point: which canvas.
    ///
    /// An empty expected host is refused rather than matched, so a source that could not be
    /// addressed fails closed instead of accepting everything.
    static func accepts(
        isMainFrame: Bool, originScheme: String?, originHost: String?, expectedHost: String
    ) -> Bool {
        guard isMainFrame, !expectedHost.isEmpty else { return false }
        return originScheme == scheme && originHost == expectedHost
    }
}
