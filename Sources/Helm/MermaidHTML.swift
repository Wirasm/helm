import Foundation

/// The mermaid theme, keyed off the effective appearance. Raw values are the
/// names mermaid's `initialize` accepts — nothing user-controlled is ever
/// interpolated into the scripts below.
enum MermaidTheme: String {
    case light = "default"
    case dark
}

/// Pure HTML/JS generation for the artifact pane's WKWebViews — the island
/// page that renders one diagram, and the user scripts injected into .html
/// artifacts. No WebKit imports: fully exercisable from `swift test`.
///
/// Everything is self-contained and offline: the only JavaScript involved is
/// the vendored mermaid renderer (see docs/VENDORED.md) plus the inline
/// init/sizing script — no external references, no network fetches, ever.
enum MermaidHTML {
    /// The `WKScriptMessageHandler` name the island's sizing script posts to.
    static let sizeHandlerName = "mermaidSize"

    /// Full HTML document for one diagram island. The vendored mermaid.js is
    /// injected separately via WKUserScript (at document start), so this page
    /// carries only the diagram source and the init + sizing script.
    ///
    /// - Transparent background: the island sits inline in the native pane.
    /// - The rendered SVG scales to the pane width (mermaid's `useMaxWidth`
    ///   emits width:100% + a max-width cap; the cap never overflows us).
    /// - Height: after render — and on every reflow, via ResizeObserver — the
    ///   page posts `document.documentElement.scrollHeight` to the native
    ///   side, which sizes the island's frame to fit the diagram exactly.
    static func islandPage(diagram: String, theme: MermaidTheme) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
          pre.mermaid { margin: 0; }
          pre.mermaid svg { max-width: 100%; }
        </style>
        </head>
        <body>
        <pre class="mermaid">\(escaped(diagram))</pre>
        <script>
        (function () {
          var post = function () {
            if (window.webkit && window.webkit.messageHandlers.\(sizeHandlerName)) {
              window.webkit.messageHandlers.\(sizeHandlerName)
                .postMessage(document.documentElement.scrollHeight);
            }
          };
          if (!window.mermaid) { post(); return; }
          mermaid.initialize({
            startOnLoad: false,
            securityLevel: "strict",
            theme: "\(theme.rawValue)"
          });
          mermaid.run().then(post, post);
          new ResizeObserver(post).observe(document.body);
        })();
        </script>
        </body>
        </html>
        """
    }

    /// Injected into .html artifacts (at document end, after the vendored
    /// mermaid.js at document start) so `<pre class="mermaid">` blocks render —
    /// the prp-diagram skill's documented alternative where "the consuming UI
    /// provides the renderer". A page without mermaid blocks is left untouched.
    static func htmlArtifactInitScript(theme: MermaidTheme) -> String {
        """
        (function () {
          if (!window.mermaid) { return; }
          if (!document.querySelector(".mermaid")) { return; }
          mermaid.initialize({
            startOnLoad: false,
            securityLevel: "strict",
            theme: "\(theme.rawValue)"
          });
          mermaid.run();
        })();
        """
    }

    /// Escapes diagram source for embedding in the island's `<pre>` element.
    /// Mermaid reads the element's textContent, so entities round-trip.
    static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The vendored mermaid.min.js source (see docs/VENDORED.md for the pinned
    /// version + hash), loaded once from the bundle. `nil` only if the bundle
    /// is broken — islands then fall back to a zero-height blank, and the
    /// markdown around them still renders.
    static func vendoredScript() -> String? { cachedVendoredScript }

    private static let cachedVendoredScript: String? = {
        // SPM builds (swift run/test) resolve resources via Bundle.module;
        // the XcodeGen .app carries them in the main bundle.
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "mermaid.min", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()
}
