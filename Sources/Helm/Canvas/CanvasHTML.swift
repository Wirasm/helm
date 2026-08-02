import Foundation

/// The canvas's theme, keyed off the effective appearance. Raw values
/// are the names mermaid's `initialize` accepts — nothing user-controlled is
/// ever interpolated into the scripts below.
enum CanvasTheme: String {
    case light = "default"
    case dark
}

/// Pure HTML/JS generation for the canvas's WKWebViews — the single
/// document page that renders a whole markdown artifact (marked converts it
/// client-side, mermaid renders its ```mermaid fences), and the init script
/// injected into .html artifacts. No WebKit imports: fully exercisable from
/// `swift test`.
///
/// Everything is self-contained and offline: the only JavaScript involved is
/// the vendored marked + mermaid (see docs/VENDORED.md) plus the inline init
/// script — no external references, no network fetches, ever.
enum CanvasHTML {
    // MARK: Document page

    /// Full HTML document for one markdown artifact. The vendored marked.js +
    /// mermaid.js are injected separately via WKUserScript (at document
    /// start), so this page carries only the markdown source (as a JS string)
    /// and the convert + render script:
    ///
    /// 1. `marked.parse` converts the markdown to HTML.
    /// 2. ```mermaid fences arrive as `<pre><code class="language-mermaid">`
    ///    blocks; they're rewritten to `<pre class="mermaid">` containers.
    /// 3. `mermaid.run()` renders them in the matching theme, at natural size
    ///    (`useMaxWidth: false`) — a wide diagram scrolls horizontally in its
    ///    own block; overall fit is the window's/zoom's job, not per-diagram
    ///    machinery.
    ///
    /// The CSS is the document type scale (15px body, 760px measure centered,
    /// 24/19/16 heading scale) over CSS system colors, so the page follows the
    /// pane's light/dark appearance via `color-scheme`.
    static func documentPage(markdown: String, theme: CanvasTheme) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        \(documentCSS(theme: theme))
        </style>
        </head>
        <body>
        <article id="content"></article>
        <script>
        (function () {
          var source = \(jsString(markdown));
          var content = document.getElementById("content");
          if (!window.marked) { content.textContent = source; return; }
          content.innerHTML = marked.parse(source);
          document.querySelectorAll("pre > code.language-mermaid").forEach(function (code) {
            var pre = document.createElement("pre");
            pre.className = "mermaid";
            pre.textContent = code.textContent;
            code.parentElement.replaceWith(pre);
          });
          if (window.mermaid && document.querySelector(".mermaid")) {
            mermaid.initialize({
              startOnLoad: false,
              securityLevel: "strict",
              theme: "\(theme.rawValue)",
              \(useMaxWidthOverrides)
            });
            mermaid.run();
          }
        })();
        </script>
        </body>
        </html>
        """
    }

    /// The document type scale as CSS — ported from the retired
    /// `MarkdownTheme.document` profile (15px body, 760px measure, 24/19/16
    /// headings, hairline under h1, monospaced code with a subtle fill).
    /// System colors (`Canvas`/`CanvasText`) + `color-scheme` keep the page in
    /// step with the app's appearance.
    private static func documentCSS(theme: CanvasTheme) -> String {
        """
        :root { color-scheme: \(theme == .dark ? "dark" : "light"); }
        body {
          margin: 0;
          background: Canvas;
          color: CanvasText;
          font: 15px/1.5 -apple-system, system-ui, sans-serif;
        }
        article { max-width: 760px; margin: 0 auto; padding: 20px 16px 40px; }
        h1 { font-size: 24px; font-weight: 700; margin: 20px 0 10px;
             padding-bottom: 6px; border-bottom: 1px solid color-mix(in srgb, CanvasText 15%, transparent); }
        h2 { font-size: 19px; font-weight: 600; margin: 18px 0 8px; }
        h3, h4, h5, h6 { font-size: 16px; font-weight: 600; margin: 16px 0 8px; }
        p, ul, ol, table, blockquote { margin: 10px 0; }
        li { margin: 5px 0; }
        code { font: 14px ui-monospace, monospace;
               background: color-mix(in srgb, CanvasText 8%, transparent);
               border-radius: 3px; padding: 0 3px; }
        pre { background: color-mix(in srgb, CanvasText 6%, transparent);
              border-radius: 6px; padding: 12px; overflow-x: auto; margin: 10px 0; }
        pre code { font-size: 13.5px; background: none; padding: 0; }
        /* Diagrams break OUT of the 760px text measure to the full pane width, and
           the natural-size SVG scales down to fit it — so widening the window shows
           the whole diagram; zoom covers the rest. Prose keeps the measure. */
        pre.mermaid { background: none; padding: 0; line-height: 0;
                      width: calc(100vw - 32px); margin-left: calc(50% - 50vw + 16px); }
        pre.mermaid svg { max-width: 100%; height: auto; display: block; margin: 0 auto; }
        blockquote { border-left: 3px solid color-mix(in srgb, CanvasText 20%, transparent);
                     padding-left: 12px; color: color-mix(in srgb, CanvasText 65%, Canvas); }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid color-mix(in srgb, CanvasText 20%, transparent);
                 padding: 4px 9px; text-align: left; }
        img { max-width: 100%; }
        hr { border: none; border-top: 1px solid color-mix(in srgb, CanvasText 15%, transparent); }
        a { color: LinkText; }
        """
    }

    /// `useMaxWidth: false` for every diagram family mermaid 11 scales by
    /// default — diagrams render at their laid-out size so node text stays
    /// readable, scrolling horizontally when wider than the measure.
    private static let useMaxWidthOverrides = [
        "flowchart", "sequence", "gantt", "journey", "timeline", "class",
        "state", "er", "pie", "quadrantChart", "xyChart", "requirement",
        "mindmap", "gitGraph", "c4", "sankey", "block", "packet", "architecture",
    ]
    .map { "\($0): { useMaxWidth: false }" }
    .joined(separator: ",\n      ")

    // MARK: .html artifacts

    /// Injected into .html artifacts (at document end, after the vendored
    /// mermaid.js at document start) so `<pre class="mermaid">` blocks render —
    /// the prp-diagram skill's documented alternative where "the consuming UI
    /// provides the renderer". A page without mermaid blocks is left untouched.
    static func htmlArtifactInitScript(theme: CanvasTheme) -> String {
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

    // MARK: Embedding helpers

    /// The markdown source as a JS string literal, via JSON encoding — quotes,
    /// newlines, and unicode handled, and `/` escaped to `\\/` so a literal
    /// `</script>` in an artifact can never terminate the page's script tag.
    static func jsString(_ text: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [text]),
            let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    // MARK: Vendored scripts

    /// The vendored marked build (see docs/VENDORED.md for the pinned version
    /// + hash), loaded once from the bundle. `nil` only if the bundle is
    /// broken — the document page then falls back to showing the raw text.
    static func vendoredMarked() -> String? { cachedMarked }

    /// The vendored mermaid build (see docs/VENDORED.md). `nil` only if the
    /// bundle is broken — diagrams then stay as unrendered mermaid containers,
    /// and the document around them still renders.
    static func vendoredMermaid() -> String? { cachedMermaid }

    private static let cachedMarked: String? = vendoredScript(named: "marked.min")
    private static let cachedMermaid: String? = vendoredScript(named: "mermaid.min")

    private static func vendoredScript(named name: String) -> String? {
        // SPM builds (swift run/test) resolve resources via Bundle.module;
        // the XcodeGen .app carries them in the main bundle.
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
