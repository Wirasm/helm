import XCTest
@testable import Helm

/// The island page + injection script generation, exercised as pure string
/// functions — no WebKit, no GUI.
final class MermaidHTMLTests: XCTestCase {
    func testEscapingNeutralizesMarkup() {
        XCTAssertEqual(
            MermaidHTML.escaped("A --> B & <script>\"x\"</script>"),
            "A --&gt; B &amp; &lt;script&gt;\"x\"&lt;/script&gt;"
        )
    }

    func testIslandPageEmbedsEscapedDiagramInMermaidPre() {
        let page = MermaidHTML.islandPage(
            diagram: "graph TD; A-->B", theme: .light
        )
        XCTAssertTrue(page.contains("<pre class=\"mermaid\">graph TD; A--&gt;B</pre>"))
        // The raw source must never land unescaped in the page.
        XCTAssertFalse(page.contains("A-->B"))
    }

    func testIslandPageCarriesTheme() {
        XCTAssertTrue(
            MermaidHTML.islandPage(diagram: "graph TD", theme: .dark)
                .contains("theme: \"dark\"")
        )
        XCTAssertTrue(
            MermaidHTML.islandPage(diagram: "graph TD", theme: .light)
                .contains("theme: \"default\"")
        )
    }

    func testIslandPageIsTransparentAndSelfContained() {
        let page = MermaidHTML.islandPage(diagram: "graph TD", theme: .light)
        XCTAssertTrue(page.contains("background: transparent"))
        // Offline rule: no external references of any kind — mermaid.js itself
        // arrives via WKUserScript, not a script tag.
        XCTAssertFalse(page.contains("src="))
        XCTAssertFalse(page.contains("http"))
    }

    func testIslandPagePostsHeightToTheSizeHandler() {
        let page = MermaidHTML.islandPage(diagram: "graph TD", theme: .light)
        XCTAssertTrue(page.contains("messageHandlers.\(MermaidHTML.sizeHandlerName)"))
        XCTAssertTrue(page.contains("scrollHeight"))
        XCTAssertTrue(page.contains("ResizeObserver"), "must re-post on reflow")
    }

    func testIslandPageRendersNaturalSizeByDefault() {
        let page = MermaidHTML.islandPage(diagram: "graph TD", theme: .light)
        // Natural size across diagram families — fitting is CSS's job, never
        // mermaid's built-in scale-to-container.
        XCTAssertTrue(page.contains("flowchart: { useMaxWidth: false }"))
        XCTAssertTrue(page.contains("sequence: { useMaxWidth: false }"))
        XCTAssertTrue(page.contains("<body class=\"natural\">"))
        // Wider-than-pane diagrams scroll horizontally inside the island.
        XCTAssertTrue(page.contains("#wrap { overflow-x: auto;"))
    }

    func testIslandPageFitModeScalesTheSVGViaCSS() {
        let page = MermaidHTML.islandPage(
            diagram: "graph TD", theme: .light, sizing: .fitWidth
        )
        XCTAssertTrue(page.contains("<body class=\"fit\">"))
        XCTAssertTrue(
            page.contains("body.fit pre.mermaid svg { max-width: 100%; height: auto; }"),
            "fit mode must scale via CSS, keeping aspect ratio"
        )
        // The mermaid config stays natural in both modes.
        XCTAssertTrue(page.contains("useMaxWidth: false"))
    }

    func testIslandPageMeasuresTheRenderedSVGNotTheDocument() {
        let page = MermaidHTML.islandPage(diagram: "graph TD", theme: .light)
        // Height comes from the SVG's real box after mermaid.run resolves —
        // documentElement.scrollHeight is only the no-SVG fallback.
        XCTAssertTrue(page.contains("getBoundingClientRect"))
        XCTAssertTrue(page.contains("mermaid.run().then(settle, settle)"))
        // Reflows re-measure via observers on the SVG/container, not body.
        XCTAssertTrue(page.contains("observer.observe(svg)"))
        XCTAssertFalse(page.contains("observe(document.body)"))
    }

    func testHTMLArtifactInitScriptCarriesThemeAndTargetsMermaidBlocks() {
        let script = MermaidHTML.htmlArtifactInitScript(theme: .dark)
        XCTAssertTrue(script.contains("theme: \"dark\""))
        XCTAssertTrue(script.contains(".mermaid"))
        XCTAssertTrue(script.contains("mermaid.run()"))
    }

    func testVendoredScriptIsBundledAndExposesTheGlobal() {
        let script = MermaidHTML.vendoredScript()
        XCTAssertNotNil(script, "mermaid.min.js must ship in the bundle")
        XCTAssertTrue(
            script?.contains("globalThis[\"mermaid\"]") == true,
            "vendored build must assign the global the injection relies on"
        )
    }
}
