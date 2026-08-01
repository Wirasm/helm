import Foundation

/// Which URLs the canvas's URL source will follow, and how a typed address
/// becomes one.
///
/// The **opposite** policy to `ArtifactWebCoordinator`'s, which cancels every
/// navigation that is not `file:` — deliberately, because that coordinator serves
/// local artifacts. This one serves a dev server, so it allows the web and nothing
/// else: an app scheme reached through a redirect (`ssh:`, `x-apple.systempreferences:`)
/// or a `javascript:` link is still refused, and `file:` stays with the source that
/// owns it.
///
/// Pure on purpose, exactly like `TerminalURLPolicy`: a `WKNavigationAction` cannot
/// be built in a test, so the decision lives here where `swift test` can reach it and
/// the coordinator is left with nothing but the plumbing.
enum CanvasURLPolicy {
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// Whether the canvas may navigate to this URL.
    static func allows(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// A typed address → the URL to load, or nil when it is not one.
    ///
    /// `localhost:3000` is the address this exists for and it is also the hard case:
    /// `URL(string:)` reads it as scheme `localhost` with path `3000`. The rule is
    /// what a browser bar does — a colon followed by digits is a **port**, anything
    /// else is a **scheme** and is taken at its word. Taking it at its word is what
    /// makes `ssh://host` a refusal rather than a rewrite into `http://ssh://host`.
    ///
    /// No search fallback: helm is not a browser, and an address that resolves to
    /// nothing is better refused than guessed at.
    static func address(_ typed: String) -> URL? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = "http://" + trimmed
        if let colon = trimmed.firstIndex(of: ":") {
            let rest = trimmed[trimmed.index(after: colon)...]
            if !isPort(rest) {
                guard allowedSchemes.contains(trimmed[..<colon].lowercased()) else { return nil }
                candidate = trimmed
            }
        }

        let url = URL(string: candidate)
        // A host is required: `http://` and `http:///path` are not addresses.
        guard allows(url), let host = url?.host(), !host.isEmpty else { return nil }
        return url
    }

    /// True when what follows the colon is a port — digits up to the path, and
    /// nothing else. `3000` and `8080/status` are ports; `alert(1)` and `//host`
    /// are not.
    private static func isPort(_ rest: Substring) -> Bool {
        let digits = rest.prefix { $0 != "/" }
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
