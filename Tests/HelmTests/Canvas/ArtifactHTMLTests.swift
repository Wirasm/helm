import XCTest

@testable import Helm

/// The document page + injection script generation, exercised as pure string
/// functions — no WebKit, no GUI.
final class ArtifactHTMLTests: XCTestCase {
    // MARK: File-kind routing

    func testMarkdownExtensionsDetected() {
        XCTAssertTrue(ArtifactHTML.isMarkdown(URL(fileURLWithPath: "/a/plan.md")))
        XCTAssertTrue(ArtifactHTML.isMarkdown(URL(fileURLWithPath: "/a/PLAN.MD")))
        XCTAssertTrue(ArtifactHTML.isMarkdown(URL(fileURLWithPath: "/a/notes.markdown")))
        XCTAssertFalse(ArtifactHTML.isMarkdown(URL(fileURLWithPath: "/a/build.log")))
        XCTAssertFalse(ArtifactHTML.isMarkdown(URL(fileURLWithPath: "/a/script.sh")))
    }

    func testHTMLExtensionsDetected() {
        XCTAssertTrue(ArtifactHTML.isHTML(URL(fileURLWithPath: "/a/page.html")))
        XCTAssertTrue(ArtifactHTML.isHTML(URL(fileURLWithPath: "/a/PAGE.HTM")))
        XCTAssertFalse(ArtifactHTML.isHTML(URL(fileURLWithPath: "/a/plan.md")))
    }

    // MARK: JS string embedding

    func testJsStringRoundTripsThroughJSON() throws {
        let source = "# Title\n\"quotes\" and \\backslashes\\ and \u{1F600}"
        let literal = ArtifactHTML.jsString(source)
        // The literal must be valid JSON encoding of the original string.
        let decoded = try JSONDecoder().decode(
            [String].self, from: Data("[\(literal)]".utf8)
        )
        XCTAssertEqual(decoded, [source])
    }

    func testJsStringNeutralizesScriptCloseTags() {
        let literal = ArtifactHTML.jsString("evil </script><script>alert(1)</script>")
        XCTAssertFalse(
            literal.contains("</script>"),
            "a literal </script> in an artifact must never terminate the page's script tag"
        )
    }

    // MARK: Document page

    func testDocumentPageEmbedsSourceAndWiresMarked() {
        let page = ArtifactHTML.documentPage(markdown: "# Hello \"plan\"\nline two", theme: .light)
        XCTAssertTrue(page.contains("marked.parse(source)"))
        // The source arrives as a JS string literal, not as page markup.
        XCTAssertTrue(
            page.contains("var source = " + ArtifactHTML.jsString("# Hello \"plan\"\nline two")))
        // Missing-renderer fallback shows the raw text instead of a blank pane.
        XCTAssertTrue(page.contains("content.textContent = source"))
    }

    func testDocumentPageRewritesMermaidFencesAndRuns() {
        let page = ArtifactHTML.documentPage(markdown: "x", theme: .light)
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
        let dark = ArtifactHTML.documentPage(markdown: "x", theme: .dark)
        XCTAssertTrue(dark.contains("theme: \"dark\""))
        XCTAssertTrue(dark.contains("color-scheme: dark"))
        let light = ArtifactHTML.documentPage(markdown: "x", theme: .light)
        XCTAssertTrue(light.contains("theme: \"default\""))
        XCTAssertTrue(light.contains("color-scheme: light"))
    }

    func testDocumentPageCarriesTheDocumentTypeScale() {
        let page = ArtifactHTML.documentPage(markdown: "x", theme: .light)
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
        let page = ArtifactHTML.documentPage(markdown: "offline", theme: .light)
        // Offline rule: no external references of any kind — marked and
        // mermaid arrive via WKUserScript, not script tags.
        XCTAssertFalse(page.contains("src="))
        XCTAssertFalse(page.contains("http"))
    }

    // MARK: .html artifact injection

    func testHTMLArtifactInitScriptCarriesThemeAndTargetsMermaidBlocks() {
        let script = ArtifactHTML.htmlArtifactInitScript(theme: .dark)
        XCTAssertTrue(script.contains("theme: \"dark\""))
        XCTAssertTrue(script.contains(".mermaid"))
        XCTAssertTrue(script.contains("mermaid.run()"))
    }

    // MARK: Vendored scripts

    func testVendoredScriptsAreBundledAndExposeTheirGlobals() {
        let mermaid = ArtifactHTML.vendoredMermaid()
        XCTAssertNotNil(mermaid, "mermaid.min.js must ship in the bundle")
        XCTAssertTrue(
            mermaid?.contains("globalThis[\"mermaid\"]") == true,
            "vendored mermaid build must assign the global the injection relies on"
        )

        let marked = ArtifactHTML.vendoredMarked()
        XCTAssertNotNil(marked, "marked.min.js must ship in the bundle")
        XCTAssertTrue(
            marked?.contains("g[\"marked\"]=f()") == true,
            "vendored marked build must assign the global the injection relies on"
        )
    }
}
