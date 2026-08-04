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
    /// `deterministicIds: true` is load-bearing, not tidiness. Left unset, mermaid
    /// seeds its id generator from `Date.now()` (`InitIDGenerator`), so every render
    /// gives a node a different DOM id — and `FileWatcher` re-renders on each agent
    /// write. An annotation would anchor to `#mermaid-1785839165688-flowchart-phase2-1`,
    /// which is stale before the operator finishes typing the comment. See
    /// `MermaidAnchor` for the other half: reducing that id to the fence identifier.
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
              deterministicIds: true,
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
            deterministicIds: true,
            theme: "\(theme.rawValue)"
          });
          mermaid.run();
        })();
        """
    }

    // MARK: The annotation bridge

    /// The name the page reads to know which tool the operator is holding. Set from Swift
    /// with `evaluateJavaScript` rather than baked into the script, so switching tools does
    /// not reload the document and lose the scroll position — a canvas is something you are
    /// part-way down when you decide to mark it.
    static let markToolGlobal = "__helmMarkTool"

    /// One statement, so `CanvasFileViews` has no JS of its own to get wrong.
    static func setMarkTool(_ tool: CanvasMarkTool) -> String {
        """
        window.\(markToolGlobal) = \(jsString(tool.token));
        if (window.__helmWipeMark) { window.__helmWipeMark(); }
        """
    }

    /// Reports what the operator selected, so helm can anchor a comment to it.
    ///
    /// On `mouseup` it reads the selection, walks up from
    /// `range.commonAncestorContainer` to the nearest ancestor carrying an `id`, and posts
    /// `{ id, text, rect }`.
    ///
    /// A `mouseup` that left **nothing** selected posts `{ cleared: true }` instead of
    /// nothing at all — that is the operator clicking away from a selection they had, and
    /// it is what lets the comment field close the way every popover does (#165). It costs
    /// one message per click on the page and no state in it; the model decides what a
    /// cleared report means.
    ///
    /// **The script is helm's, not the canvas's, and the canvas must render correctly
    /// without it.** A page that depended on a helm-injected global would render in helm
    /// and be a blank page in `playwright-cli`, so the agent would validate a different
    /// artifact from the one it is shown (#33). This may only read and report; it must
    /// never be something the page needs.
    ///
    /// The rect is the selection's position in the viewport, so the comment field can be
    /// anchored near what it is about. It is not part of the anchor and is never persisted
    /// — an anchor made of coordinates would not survive the agent rewriting the page,
    /// which is the whole thing it has to survive.
    static func annotationScript() -> String {
        """
        (function () {
          if (!window.webkit || !window.webkit.messageHandlers
              || !window.webkit.messageHandlers.\(CanvasBridgePolicy.handlerName)) { return; }
          var bridge = window.webkit.messageHandlers.\(CanvasBridgePolicy.handlerName);
          if (!window.\(markToolGlobal)) { window.\(markToolGlobal) = "select"; }
          function tool() { return window.\(markToolGlobal) || "select"; }

          // The nearest ancestor carrying an id, and the text it covers. ONE resolver, used
          // by every tool — #112 asks for the draw-time hit test and any later re-resolution
          // to share a code path, because inconsistent resolution between capture and action
          // is its own bug class.
          function resolve(node) {
            if (!node) { return null; }
            if (node.nodeType === 3) { node = node.parentNode; }
            var labelled = node;
            var id = null;
            while (node && node !== document.body) {
              if (node.id) { id = node.id; break; }
              node = node.parentNode;
            }
            var text = ((node || labelled).textContent || "").trim().slice(0, 400);
            if (!text) { return null; }
            return { id: id, text: text };
          }

          function targetAt(x, y) {
            if (paper) { paper.style.display = "none"; }
            var hit = document.elementFromPoint(x, y);
            if (paper) { paper.style.display = ""; }
            return resolve(hit);
          }

          // Ray casting. A freehand loop is treated as closed, because a person circling
          // something does not carefully meet the ends and helm should not make them.
          function inside(poly, x, y) {
            var yes = false;
            for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
              var xi = poly[i].x, yi = poly[i].y, xj = poly[j].x, yj = poly[j].y;
              if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) {
                yes = !yes;
              }
            }
            return yes;
          }

          // Everything the loop encircles, by CENTRE rather than by any overlap: a stroke
          // that grazes a neighbour did not mean the neighbour.
          function targetsInside(poly) {
            var seen = {}, found = [];
            var nodes = document.querySelectorAll("[id], p, li, td, th, h1, h2, h3");
            for (var i = 0; i < nodes.length; i++) {
              if (nodes[i].closest("[data-helm-mark]")) { continue; }
              var r = nodes[i].getBoundingClientRect();
              if (!r.width && !r.height) { continue; }
              if (!inside(poly, r.left + r.width / 2, r.top + r.height / 2)) { continue; }
              var t = resolve(nodes[i]);
              if (!t) { continue; }
              var key = (t.id || "") + "\\u0000" + t.text;
              if (seen[key]) { continue; }
              seen[key] = true;
              found.push(t);
            }
            return found;
          }

          // The ink. helm's own chrome, marked as such so an agent reading the DOM can tell
          // it from what it authored, and inert so the page can never come to need it.
          var paper = null, ink = null, stroke = [], from = null;

          function sheet() {
            if (paper) { return paper; }
            paper = document.createElementNS("http://www.w3.org/2000/svg", "svg");
            paper.setAttribute("data-helm-mark", "");
            paper.style.cssText =
              "position:fixed;left:0;top:0;width:100vw;height:100vh;" +
              "pointer-events:none;z-index:2147483647;overflow:visible";
            // The arrowhead `marker-end` points at. An unresolvable url() is IGNORED rather
            // than erroring, so without this the arrow tool silently drew a bare line — the
            // one cue that tells it apart from freehand while you are drawing.
            //
            // Built with DOM calls rather than a markup string: this script reads and
            // reports and never writes markup, which is an invariant with a test on it, and
            // a markup string here is the shape that quietly becomes an injection vector.
            var svgNS = "http://www.w3.org/2000/svg";
            var defs = document.createElementNS(svgNS, "defs");
            var marker = document.createElementNS(svgNS, "marker");
            marker.setAttribute("id", "helm-mark-head");
            marker.setAttribute("markerWidth", "8");
            marker.setAttribute("markerHeight", "8");
            marker.setAttribute("refX", "6");
            marker.setAttribute("refY", "3");
            marker.setAttribute("orient", "auto");
            var barb = document.createElementNS(svgNS, "path");
            barb.setAttribute("d", "M0,0 L6,3 L0,6 Z");
            barb.setAttribute("fill", "currentColor");
            marker.appendChild(barb);
            defs.appendChild(marker);
            paper.appendChild(defs);
            document.body.appendChild(paper);
            return paper;
          }

          function draw(d, head) {
            var svg = sheet();
            if (!ink) {
              ink = document.createElementNS("http://www.w3.org/2000/svg", "path");
              ink.setAttribute("fill", "none");
              ink.setAttribute("stroke", "currentColor");
              ink.setAttribute("stroke-width", "2.5");
              ink.setAttribute("stroke-linecap", "round");
              ink.setAttribute("stroke-linejoin", "round");
              ink.setAttribute("opacity", "0.85");
              if (head) { ink.setAttribute("marker-end", "url(#helm-mark-head)"); }
              svg.appendChild(ink);
            }
            ink.setAttribute("d", d);
          }

          function wipe() {
            if (paper && paper.parentNode) { paper.parentNode.removeChild(paper); }
            paper = null; ink = null; stroke = []; from = null;
          }

          // A drag released outside the document — over helm's own header, another pane —
          // never fires mouseup here, and the ink would sit at max z-index until the next
          // stroke. Both of these end it.
          window.addEventListener("blur", wipe);
          document.addEventListener("mouseleave", wipe);
          // Called from Swift when the tool changes, so putting a tool down also drops
          // whatever was half-drawn with it.
          window.__helmWipeMark = wipe;

          function pathFrom(points) {
            var d = "M" + points[0].x + " " + points[0].y;
            for (var i = 1; i < points.length; i++) {
              d += " L" + points[i].x + " " + points[i].y;
            }
            return d;
          }

          function bounds(points) {
            var l = Infinity, r = -Infinity, t = Infinity, b = -Infinity;
            for (var i = 0; i < points.length; i++) {
              l = Math.min(l, points[i].x); r = Math.max(r, points[i].x);
              t = Math.min(t, points[i].y); b = Math.max(b, points[i].y);
            }
            return { x: l, y: t, width: r - l, height: b - t };
          }

          document.addEventListener("mousedown", function (e) {
            var t = tool();
            if (t === "select") { return; }
            // Primary button only. A tool is a STICKY selection, unlike the modifier it
            // replaced — so a right-click for the page's own context menu would otherwise
            // start a stroke, and the menu's tracking loop eats the matching mouseup.
            if (e.button !== 0) { return; }
            e.preventDefault();
            wipe();
            stroke = [{ x: e.clientX, y: e.clientY }];
            from = targetAt(e.clientX, e.clientY);
          }, true);

          document.addEventListener("mousemove", function (e) {
            if (!stroke.length) { return; }
            var t = tool();
            if (t === "point") { return; }
            stroke.push({ x: e.clientX, y: e.clientY });
            if (t === "arrow") {
              draw(pathFrom([stroke[0], stroke[stroke.length - 1]]), true);
            } else {
              draw(pathFrom(stroke), false);
            }
          }, true);

          document.addEventListener("mouseup", function (e) {
            var t = tool();

            if (t === "select") {
              // Unchanged: the text selection helm has always reported.
              var selection = document.getSelection();
              var empty = !selection || selection.isCollapsed || selection.rangeCount === 0;
              var text = empty ? "" : String(selection).trim();
              if (!text) { bridge.postMessage({ cleared: true }); return; }
              var range = selection.getRangeAt(0);
              var node = range.commonAncestorContainer;
              if (node.nodeType === 3) { node = node.parentNode; }
              var id = null;
              while (node && node !== document.body) {
                if (node.id) { id = node.id; break; }
                node = node.parentNode;
              }
              var r = range.getBoundingClientRect();
              bridge.postMessage({
                id: id, text: text,
                rect: { x: r.left, y: r.top, width: r.width, height: r.height }
              });
              return;
            }

            if (!stroke.length) { return; }
            var start = stroke[0], startTarget = from;
            var box = bounds(stroke.concat([{ x: e.clientX, y: e.clientY }]));
            var drawn = stroke.slice();
            wipe();
            stroke = []; from = null;

            if (t === "point") {
              var at = targetAt(e.clientX, e.clientY);
              if (!at) { bridge.postMessage({ cleared: true }); return; }
              bridge.postMessage({ mark: "point", id: at.id, text: at.text, rect: box });
              return;
            }

            if (t === "arrow") {
              var end = targetAt(e.clientX, e.clientY);
              // Either end may be empty — an arrow into blank space is "add a node here".
              bridge.postMessage({ mark: "relation", from: startTarget, to: end, rect: box });
              return;
            }

            if (t === "freehand") {
              // What the loop encircles. Posted even when empty, so decode refuses it
              // visibly — silence is indistinguishable from the stroke never registering.
              bridge.postMessage({
                mark: "enclosure", targets: targetsInside(drawn), rect: box
              });
              return;
            }

            // A tool helm does not know. Do nothing rather than guess — freehand used to be
            // the fall-through here, so a garbage token silently drew a circle.
          }, true);
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
