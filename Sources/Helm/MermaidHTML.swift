import Foundation

/// The mermaid theme, keyed off the effective appearance. Raw values are the
/// names mermaid's `initialize` accepts — nothing user-controlled is ever
/// interpolated into the scripts below.
enum MermaidTheme: String {
    case light = "default"
    case dark
}

/// How an island page sizes its rendered SVG. Natural is the default: the
/// diagram renders at the size mermaid laid it out, and the island scrolls
/// horizontally when the pane is narrower. Fit-width scales the SVG down to
/// the pane via CSS (never up) — a per-island, user-toggled mode.
enum MermaidSizing: String {
    case natural
    case fitWidth = "fit"
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
    /// - Natural size: `useMaxWidth: false` across diagram types, so mermaid
    ///   emits the SVG at its laid-out size and node text stays readable; the
    ///   `#wrap` container scrolls horizontally when the pane is narrower.
    ///   Fit-width mode instead scales the SVG down via CSS (`max-width`).
    /// - Height: after `mermaid.run()` resolves, the page measures the
    ///   rendered SVG's actual bounding box (`getBoundingClientRect`) — not
    ///   `scrollHeight`, which lies before layout settles — and posts it to
    ///   the native side; a ResizeObserver on the SVG and its container
    ///   re-posts on every reflow.
    static func islandPage(
        diagram: String,
        theme: MermaidTheme,
        sizing: MermaidSizing = .natural
    ) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; overflow-x: hidden; }
          #wrap { overflow-x: auto; overflow-y: hidden; }
          pre.mermaid { margin: 0; line-height: 0; }
          pre.mermaid svg { display: block; }
          body.fit #wrap { overflow-x: hidden; }
          body.fit pre.mermaid svg { max-width: 100%; height: auto; }
        </style>
        </head>
        <body class="\(sizing.rawValue)">
        <div id="wrap"><pre class="mermaid">\(escaped(diagram))</pre></div>
        <script>
        (function () {
          var post = function (height) {
            if (window.webkit && window.webkit.messageHandlers.\(sizeHandlerName)) {
              window.webkit.messageHandlers.\(sizeHandlerName).postMessage(height);
            }
          };
          var wrap = document.getElementById("wrap");
          var measure = function () {
            var svg = wrap ? wrap.querySelector("svg") : null;
            if (!svg) { post(document.documentElement.scrollHeight); return; }
            // The SVG's real box plus the container's chrome (a horizontal
            // scrollbar, when classic scrollbars take up space).
            var box = svg.getBoundingClientRect().height;
            var chrome = wrap.offsetHeight - wrap.clientHeight;
            post(Math.ceil(box + Math.max(chrome, 0)));
          };
          if (!window.mermaid) { post(document.documentElement.scrollHeight); return; }
          mermaid.initialize({
            startOnLoad: false,
            securityLevel: "strict",
            theme: "\(theme.rawValue)",
            \(useMaxWidthOverrides)
          });
          var settle = function () {
            var svg = wrap ? wrap.querySelector("svg") : null;
            var observer = new ResizeObserver(measure);
            if (svg) { observer.observe(svg); }
            if (wrap) { observer.observe(wrap); }
            requestAnimationFrame(measure);
          };
          mermaid.run().then(settle, settle);
        })();
        </script>
        </body>
        </html>
        """
    }

    /// `useMaxWidth: false` for every diagram family mermaid 11 scales by
    /// default — natural size is the island's baseline; fitting is CSS's job.
    private static let useMaxWidthOverrides = [
        "flowchart", "sequence", "gantt", "journey", "timeline", "class",
        "state", "er", "pie", "quadrantChart", "xyChart", "requirement",
        "mindmap", "gitGraph", "c4", "sankey", "block", "packet", "architecture",
    ]
    .map { "\($0): { useMaxWidth: false }" }
    .joined(separator: ",\n    ")

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
