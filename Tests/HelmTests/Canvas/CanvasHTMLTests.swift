import XCTest

@testable import Helm

/// The document page + injection script generation, exercised as pure string
/// functions — no WebKit, no GUI.
final class CanvasHTMLTests: XCTestCase {
    // MARK: JS string embedding

    func testJsStringRoundTripsThroughJSON() throws {
        let source = "# Title\n\"quotes\" and \\backslashes\\ and \u{1F600}"
        let literal = CanvasHTML.jsString(source)
        // The literal must be valid JSON encoding of the original string.
        let decoded = try JSONDecoder().decode(
            [String].self, from: Data("[\(literal)]".utf8)
        )
        XCTAssertEqual(decoded, [source])
    }

    func testJsStringNeutralizesScriptCloseTags() {
        let literal = CanvasHTML.jsString("evil </script><script>alert(1)</script>")
        XCTAssertFalse(
            literal.contains("</script>"),
            "a literal </script> in an artifact must never terminate the page's script tag"
        )
    }

    // MARK: Document page

    func testDocumentPageEmbedsSourceAndWiresMarked() {
        let page = CanvasHTML.documentPage(markdown: "# Hello \"plan\"\nline two", theme: .light)
        XCTAssertTrue(page.contains("marked.parse(source)"))
        // The source arrives as a JS string literal, not as page markup.
        XCTAssertTrue(
            page.contains("var source = " + CanvasHTML.jsString("# Hello \"plan\"\nline two")))
        // Missing-renderer fallback shows the raw text instead of a blank pane.
        XCTAssertTrue(page.contains("content.textContent = source"))
    }

    func testDocumentPageRewritesMermaidFencesAndRuns() {
        let page = CanvasHTML.documentPage(markdown: "x", theme: .light)
        // marked emits ```mermaid fences as code blocks with a language class;
        // the page rewrites them to the containers mermaid.run targets.
        XCTAssertTrue(page.contains("code.language-mermaid"))
        XCTAssertTrue(page.contains("pre.className = \"mermaid\""))
        XCTAssertTrue(page.contains("mermaid.run()"))
        // Diagrams render at natural size; fit is the window's/zoom's job.
        XCTAssertTrue(page.contains("flowchart: { useMaxWidth: false }"))
        XCTAssertTrue(page.contains("sequence: { useMaxWidth: false }"))
    }

    func testDocumentPageCarriesTheme() {
        let dark = CanvasHTML.documentPage(markdown: "x", theme: .dark)
        XCTAssertTrue(dark.contains("theme: \"dark\""))
        XCTAssertTrue(dark.contains("color-scheme: dark"))
        let light = CanvasHTML.documentPage(markdown: "x", theme: .light)
        XCTAssertTrue(light.contains("theme: \"default\""))
        XCTAssertTrue(light.contains("color-scheme: light"))
    }

    func testDocumentPageCarriesTheDocumentTypeScale() {
        let page = CanvasHTML.documentPage(markdown: "x", theme: .light)
        // The .document scale, now CSS: 15px body over a centered 760px
        // measure, 24/19/16 headings, monospaced code with a subtle fill.
        XCTAssertTrue(page.contains("font: 15px/1.5 -apple-system"))
        XCTAssertTrue(page.contains("max-width: 760px"))
        XCTAssertTrue(page.contains("margin: 0 auto"))
        XCTAssertTrue(page.contains("h1 { font-size: 24px"))
        XCTAssertTrue(page.contains("h2 { font-size: 19px"))
        XCTAssertTrue(page.contains("h3, h4, h5, h6 { font-size: 16px"))
        XCTAssertTrue(page.contains("ui-monospace"))
    }

    func testDocumentPageIsSelfContained() {
        let page = CanvasHTML.documentPage(markdown: "offline", theme: .light)
        // Offline rule: no external references of any kind — marked and
        // mermaid arrive via WKUserScript, not script tags.
        XCTAssertFalse(page.contains("src="))
        XCTAssertFalse(page.contains("http"))
    }

    // MARK: .html artifact injection

    func testHTMLArtifactInitScriptCarriesThemeAndTargetsMermaidBlocks() {
        let script = CanvasHTML.htmlArtifactInitScript(theme: .dark)
        XCTAssertTrue(script.contains("theme: \"dark\""))
        XCTAssertTrue(script.contains(".mermaid"))
        XCTAssertTrue(script.contains("mermaid.run()"))
    }

    // MARK: Vendored scripts

    func testVendoredScriptsAreBundledAndExposeTheirGlobals() {
        let mermaid = CanvasHTML.vendoredMermaid()
        XCTAssertNotNil(mermaid, "mermaid.min.js must ship in the bundle")
        XCTAssertTrue(
            mermaid?.contains("globalThis[\"mermaid\"]") == true,
            "vendored mermaid build must assign the global the injection relies on"
        )

        let marked = CanvasHTML.vendoredMarked()
        XCTAssertNotNil(marked, "marked.min.js must ship in the bundle")
        XCTAssertTrue(
            marked?.contains("g[\"marked\"]=f()") == true,
            "vendored marked build must assign the global the injection relies on"
        )
    }
    // MARK: - The annotation bridge

    /// The script's *behaviour* is verified by driving a canvas; what is pinned here is
    /// that it is well-formed, names the handler, and reads rather than writes.
    func testTheAnnotationScriptPostsToTheNamedHandler() {
        let script = CanvasHTML.annotationScript()

        XCTAssertTrue(
            script.contains("webkit.messageHandlers.\(CanvasBridgePolicy.handlerName)"),
            script)
        XCTAssertTrue(script.contains("mouseup"), "the selection is read when it is made")
        XCTAssertTrue(script.contains("getSelection"), script)
    }

    /// **The canvas must render correctly without it.** A page that depended on a
    /// helm-injected global would render in helm and be a blank page in `playwright-cli`,
    /// so the agent would validate a different artifact from the one it is shown (#33).
    func testTheAnnotationScriptReturnsEarlyWhenThereIsNoBridge() {
        let script = CanvasHTML.annotationScript()

        XCTAssertTrue(
            script.contains("if (!window.webkit"),
            "no handler means no listener, and a page that never had one is unaffected")
        XCTAssertFalse(
            script.contains("document.write"), "the bridge reads and reports; it never writes")
        XCTAssertFalse(script.contains("innerHTML"), "…and never changes the page")
    }

    func testTheAnnotationScriptIsBalanced() {
        let script = CanvasHTML.annotationScript()

        XCTAssertEqual(
            script.filter { $0 == "{" }.count, script.filter { $0 == "}" }.count,
            "an unbalanced IIFE is a syntax error the page would swallow silently")
        XCTAssertEqual(
            script.filter { $0 == "(" }.count, script.filter { $0 == ")" }.count)
    }

}
