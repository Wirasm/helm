import Foundation

/// The canvas's theme, keyed off the effective appearance. Raw values
/// are the names mermaid's `initialize` accepts — nothing user-controlled is
/// ever interpolated into the scripts below.
enum CanvasTheme: String {
    case light = "default"
    case dark

    /// Which of a palette token's two values this theme is asking for.
    ///
    /// The canvas's own *document* deliberately renders over CSS system colours — an artifact
    /// is a document and should read like one — but anything helm draws **on top of** it is
    /// helm's chrome and spends the palette, which is what this crossing is for. Stated once
    /// here rather than at each call site, so "which appearance is a dark canvas?" has one
    /// answer on the way into the page.
    var appearance: Palette.Appearance {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
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
    /// `data-helm-frame` on the wrapper is load-bearing, not decoration: it is helm marking its
    /// own chrome, the same job `data-helm-mark` does for the ink, and `canvas-annotation.js`
    /// reads it to know that `#content` is helm's id rather than the artifact's. **Take it off
    /// and every mark on every markdown canvas anchors to `#content` again**, which is a grep
    /// that finds nothing (#215). The argument for a marker over anything the script could
    /// infer from the DOM lives beside `helmFrame`, where the inference would have been made.
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
        <article id="content" data-helm-frame></article>
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

    // MARK: Keeping an image sibling fresh (#279)

    /// The query parameter helm owns on an image's URL.
    ///
    /// Its **value means nothing to the handler** — `CanvasSchemeHandler.serve` resolves a
    /// sibling from `url.path`, which excludes the query, so a stamped request reads exactly the
    /// same file off disk. The only thing it changes is the URL, and the URL is the key.
    static let imageStampParameter = "helm"

    /// Point every image on the page at a URL this refresh has not used before.
    ///
    /// **Measured before it was written, and the measurement is the whole argument** — it lives
    /// in `CanvasSiblingFreshnessLiveTests.testAChangedQueryClearsAnImageThatANavigationDoesNot`,
    /// against a real `WKWebView` on a real `helm-canvas://` origin, with one sibling `.svg`
    /// edited between two renders:
    ///
    /// - The `<img>` keeps the old dimensions across the navigation helm performs, on a document
    ///   that demonstrably is a new one. WebKit reuses its decoded copy, keyed by URL.
    /// - Changing the query on `src` clears it, with **no navigation at all**.
    /// - A `fetch` of the identical URL returns the new bytes, so none of this is the handler's.
    ///
    /// The middle one is why this is a script rather than a rebuilt webview: a page defining
    /// `window.helmCanvasUpdate` is never navigated (`CanvasUpdate`'s contract, in one
    /// sentence), so a fix that needs a navigation could never reach the pages that need it most.
    ///
    /// **Every image on the page is re-stamped, not only the one that changed**, so a render
    /// costs one extra read of a local file per image. The precise version is a per-file mtime
    /// map, which needs a `stat` per sibling and only pays for itself on a page carrying many
    /// images; **reach for it when the difference is visible, not before**. The generation is
    /// what `CanvasUpdate` already carries, which is why it is what the stamp spends.
    ///
    /// **Same-origin only.** A `data:` URI has this document's bytes in it and a `blob:` one is
    /// the page's own object — appending a query to either would break the image outright, so
    /// the scheme and host have to match the document's before anything is touched. Two things
    /// are deliberately **out of scope** and would want their own measurement first: `srcset`,
    /// which `marked` never emits, and CSS `background-image`, which is not an element at all.
    static func restampImagesScript(generation: Int) -> String {
        """
        (function () {
          var stamp = \(jsString(String(generation)));
          var images = document.querySelectorAll("img[src]");
          for (var i = 0; i < images.length; i++) {
            var image = images[i];
            var url;
            try { url = new URL(image.src); } catch (e) { continue; }
            if (url.protocol !== location.protocol) { continue; }
            if (url.host !== location.host) { continue; }
            if (url.searchParams.get(\(jsString(imageStampParameter))) === stamp) { continue; }
            url.searchParams.set(\(jsString(imageStampParameter)), stamp);
            image.src = url.href;
          }
        })();
        """
    }

    // MARK: The annotation bridge

    /// The name the page reads to know which tool the operator is holding. Set from Swift
    /// with `evaluateJavaScript` rather than baked into the script, so switching tools does
    /// not reload the document and lose the scroll position — a canvas is something you are
    /// part-way down when you decide to mark it.
    static let markToolGlobal = "__helmMarkTool"

    /// The name the page registers its text highlight under, and the name its `::highlight()`
    /// rule selects (#308). Spelled out in `canvas-annotation.js` as well, exactly like
    /// `markToolGlobal` above and for the same reason — a JavaScript file cannot compile
    /// against a Swift constant, so `CanvasAnnotationScriptTests` is the gate over both copies.
    ///
    /// **`CSS.highlights` is the document's, shared with the page's own scripts**, so this is a
    /// name in someone else's namespace. `helm-mark` is the prefix helm already marks its chrome
    /// with (`data-helm-mark`, `helm-mark-head`), which is as much as a shared registry allows.
    static let markHighlightName = "helm-mark"

    /// The global the page reads the text mark's colour from.
    static let markTintGlobal = "__helmMarkTint"

    /// What a text mark is painted with — `Palette.helm.selection`, resolved here because only
    /// helm knows which appearance is in force.
    ///
    /// **The token is the one named for this job**: *"what a selection leaves behind: dragged
    /// text in the terminal, the selected tab"*. A canvas text mark is the third thing with that
    /// meaning, and spending the same token is what makes the three read as one application
    /// rather than as three surfaces that each picked a colour.
    ///
    /// **Resolved in Swift rather than left to CSS**, and that is the reason it crosses at all.
    /// A `prefers-color-scheme` rule in the page would follow the *system*, and helm's canvas
    /// follows helm's own `AppearanceOverride`; `light-dark()` would need the artifact to have
    /// declared a `color-scheme`, which an agent-authored `.html` need not have. `CanvasTheme`
    /// already is helm's answer, so the answer is given rather than re-derived.
    static func markTint(for theme: CanvasTheme) -> String {
        Palette.helm.selection.value(in: theme.appearance).hex
    }

    /// Take the mark down. Called when the comment field closes, submitted or dismissed —
    /// the mark is that field's subject and lives exactly as long as it does. All four marks:
    /// the page's `wipe` takes its ink and its text highlight down together (#308).
    static func clearMarkScript() -> String {
        "if (window.__helmWipeMark) { window.__helmWipeMark(); }"
    }

    /// One statement, so `CanvasFileViews` has no JS of its own to get wrong.
    ///
    /// **The tint rides here rather than on a channel of its own**, and the invariant that buys
    /// is worth stating: the only way the page has no tint is that this push never landed — and
    /// then the page is still holding `read`, which posts nothing and paints nothing. So the
    /// colour cannot be missing at the moment a text mark exists to need it, and the script is
    /// free to paint nothing at all rather than invent a fallback colour.
    static func setMarkTool(_ tool: CanvasMarkTool, theme: CanvasTheme) -> String {
        """
        window.\(markToolGlobal) = \(jsString(tool.token));
        window.\(markTintGlobal) = \(jsString(markTint(for: theme)));
        if (window.__helmAbandonMark) { window.__helmAbandonMark(); }
        """
    }

    /// Reports what the operator selected, so helm can anchor a comment to it.
    ///
    /// On `mouseup` it reads the selection, walks up from
    /// `range.commonAncestorContainer` to the nearest ancestor carrying an `id`, and posts a
    /// message whose **`kind`** says what it is.
    ///
    /// **The kinds are `CanvasPageSelection.Kind`'s, and this comment deliberately does not
    /// list them.** It used to spell the payload out — `{ id, text, rect }` for a selection,
    /// `{ cleared: true }` for a dismissal — and that was already a second copy of a shape
    /// living somewhere else. #109 changed the shape and every consumer of it, and this
    /// sentence would have been the one thing left asserting the old one as current fact: a
    /// wire format written twice, once in code and once in prose, where only the code half has
    /// a test on it. Read `CanvasPageSelection.Kind`, which is exhaustive, and
    /// `CanvasAnnotationScriptTests.testTheScriptAndSwiftStillAgreeOnEveryMessageKind`, which
    /// runs the real script and checks every case of it.
    ///
    /// A `mouseup` that left **nothing** selected posts a `cleared` message instead of nothing
    /// at all — that is the operator clicking away from a selection they had, and it is what
    /// lets the comment field close the way every popover does (#165). It costs one message per
    /// click on the page and no state in it; the model decides what a cleared report means.
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
    ///
    /// **The script itself is `Resources/canvas-annotation.js`, not a literal here** (#197).
    /// It was 298 lines of JavaScript inside a Swift string — 54% of this file — and the only
    /// test available against it was a substring check. Three consecutive PRs then shipped a
    /// defect that every one of those checks passed: #190's content world, #196's coordinate
    /// space, #208's containment rule. Two is luck; three is a property of the medium, because
    /// a string literal can only be tested by looking at the string. As a file it gets a
    /// linter, a formatter and a readable diff — and `CanvasScriptRuntime` **executes** it.
    ///
    /// **What crosses the seam is now a convention, and that is the cost of the move.** While
    /// this was one string there was nothing for the two halves to disagree about; there is
    /// now. **Three** strings are spelled out in the `.js` rather than interpolated —
    /// `CanvasBridgePolicy.handlerName`, `markToolGlobal`, and the `data-helm-frame` attribute
    /// `documentPage` writes above — and the message shape is agreed with
    /// `CanvasAnnotation.decode` by nothing the compiler can see.
    ///
    /// Two suites hold them together. `CanvasAnnotationScriptTests` asserts the file still
    /// names the first two, and feeds what the running script posts straight into the real
    /// `decode`; `CanvasAnchorTests` asserts that the page this file generates and the script
    /// that reads it still agree on the frame marker. Those are gates, not contracts —
    /// JavaScript cannot compile against a Swift type — so it is stated here rather than
    /// assumed.
    ///
    /// **A marker is a string across the seam and so is an id, so why is one better?** Because
    /// a marker is only ever wrong when this file and the script disagree, which a test can
    /// see. Recognising the frame by its *id* is wrong whenever an agent happens to use the
    /// same id, which no test of this seam can see — the artifact is not helm's to inspect.
    /// That is the whole of the #215 follow-up, and it is the reason to add a string here
    /// rather than remove one.
    ///
    /// Empty when the resource is missing, degrading exactly as a missing vendored script
    /// does: an empty user script installs no listeners, the page renders, and nothing marks.
    /// **The canvas must render correctly without it** (#33), so there is nothing to crash on.
    static func annotationScript() -> String { cachedAnnotation }

    private static let cachedAnnotation: String = {
        guard let source = bundledScript(named: "canvas-annotation") else {
            NSLog("helm: canvas-annotation.js missing from the bundle — canvases cannot be marked")
            return ""
        }
        return source
    }()

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

    // MARK: Bundled scripts

    /// The vendored marked build (see docs/VENDORED.md for the pinned version
    /// + hash), loaded once from the bundle. `nil` only if the bundle is
    /// broken — the document page then falls back to showing the raw text.
    static func vendoredMarked() -> String? { cachedMarked }

    /// The vendored mermaid build (see docs/VENDORED.md). `nil` only if the
    /// bundle is broken — diagrams then stay as unrendered mermaid containers,
    /// and the document around them still renders.
    static func vendoredMermaid() -> String? { cachedMermaid }

    private static let cachedMarked: String? = bundledScript(named: "marked.min")
    private static let cachedMermaid: String? = bundledScript(named: "mermaid.min")

    /// One loader for every `.js` in `Resources/`, vendored or helm's own. It was
    /// `vendoredScript` while marked and mermaid were the only two; `canvas-annotation.js`
    /// is helm's, needs the identical two-bundle dance, and a second copy of it would be a
    /// second thing to keep in step for no gain.
    private static func bundledScript(named name: String) -> String? {
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
