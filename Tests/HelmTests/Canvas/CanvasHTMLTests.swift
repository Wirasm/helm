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

    func testBothMermaidCallSitesAskForDeterministicIDs() {
        // Unset, mermaid seeds its id generator from Date.now(), so a node's DOM id
        // changes on every render — and FileWatcher re-renders on every agent write,
        // which is exactly when an annotation's anchor must still resolve (#113).
        XCTAssertTrue(
            CanvasHTML.documentPage(markdown: "x", theme: .light).contains(
                "deterministicIds: true"),
            "the markdown document page renders diagrams and must pin their ids")
        XCTAssertTrue(
            CanvasHTML.htmlArtifactInitScript(theme: .light).contains("deterministicIds: true"),
            ".html artifacts render diagrams through the same renderer and drift the same "
                + "way — fixing only one call site fixes half the canvases")
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

    // MARK: The mark tools (#112)

    // The script's *behaviour* moved to `CanvasAnnotationScriptTests`, which executes the
    // shipped `canvas-annotation.js` rather than reading it (#197). Nothing was dropped: the
    // tool driving the mark, the single resolver, the loop's centre test, the inert ink, the
    // arrowhead, the primary-button guard and the abandon rules are all asserted there against
    // what a gesture does. What stays here is what generating a string is still responsible
    // for — `setMarkTool` and `clearMarkScript`, which are Swift and not the resource.

    func testSettingTheToolDropsHalfDrawnWorkButNotACommittedMark() {
        // It used to wipe unconditionally. That was right when ink was transient and wrong
        // the moment it started outliving the gesture: switching tools with a comment open
        // erased the mark and left the field anchored to nothing.
        let set = CanvasHTML.setMarkTool(.select)

        XCTAssertTrue(set.contains("__helmAbandonMark"))
        XCTAssertFalse(
            set.contains("__helmWipeMark"),
            "a tool change may not remove a mark that is already awaiting its comment")
    }

    func testClearingTheMarkIsTheOneThingThatTakesAPostedOneDown() {
        // The mark is the comment field's subject and lives exactly as long as it does. That
        // it survives the release, a blur and a tool change is asserted by driving the page;
        // this is the Swift half — the statement the coordinator evaluates when the field
        // closes has to reach the global the page published.
        XCTAssertTrue(CanvasHTML.clearMarkScript().contains("__helmWipeMark"))
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

    /// **The annotation script is a bundled resource like the vendored two** (#197), and its
    /// absence has to look like theirs: nothing, quietly, rather than a crash. An empty user
    /// script installs no listeners and the canvas renders exactly as a canvas without the
    /// bridge does — which #33 requires be a working page in any case.
    func testTheAnnotationScriptShipsInTheBundle() {
        let script = CanvasHTML.annotationScript()

        XCTAssertFalse(
            script.isEmpty,
            "canvas-annotation.js must be in Package.swift's resources and project.yml's "
                + "resources phase — the two that have to stay in lockstep")
        XCTAssertTrue(script.hasPrefix("(function () {"), "and be the script, not something else")
    }

    /// The bridge reads and reports. A script that wrote to the page would make the canvas
    /// something the agent cannot validate outside helm (#33), and there is no execution that
    /// proves an absence — so this stays a check on the text.
    func testTheAnnotationScriptNeverWritesToThePage() {
        let script = CanvasHTML.annotationScript()

        XCTAssertFalse(script.contains("document.write"))
        XCTAssertFalse(script.contains("innerHTML"), "…and never changes the page")
        XCTAssertFalse(
            script.contains("altKey"),
            "marking is a tool you pick up, not a modifier you have to know about")
    }

    /// #112's own acceptance: the draw-time hit test and any later re-resolution share ONE
    /// code path, because inconsistent resolution between capture and action is its own bug
    /// class. A count of definitions, which is a fact about the text.
    func testOneResolverServesEveryTool() {
        let script = CanvasHTML.annotationScript()

        XCTAssertEqual(script.components(separatedBy: "function resolve(").count - 1, 1)
        XCTAssertTrue(
            script.contains("function targetAt(") && script.contains("function targetsInside("))
    }

}
