import WebKit
import XCTest

@testable import Helm

@MainActor
final class CanvasSourceAnchorTests: XCTestCase {
    func testSubgraphUsesItsAuthoredIdentifier() throws {
        let note = try XCTUnwrap(
            CanvasAnnotation.decode(
                posted: [
                    "kind": "selection", "anchorKind": "mermaid", "elementClass": "cluster",
                    "id": "mermaid-0-zone", "text": "The Zone",
                ], comment: "change this boundary"))
        XCTAssertEqual(note.mark, .selection(.element(id: "zone", text: "The Zone")))
    }

    func testUnsupportedDiagramCannotPersistAQuote() throws {
        let body: [String: Any] = [
            "kind": "selection", "anchorKind": "mermaid", "id": "mermaid-0",
            "text": "40%",
        ]
        guard case let .selected(selection) = try CanvasPageSelection.decode(body).get() else {
            return XCTFail("selection should still open the field")
        }
        XCTAssertNil(CanvasAnnotation.decode(selection, comment: "change this slice"))
        XCTAssertTrue(CanvasCommentField.quote(for: selection).contains("not anchorable"))
    }

    func testUnknownAnchorKindCannotBecomeAnAuthoredID() {
        XCTAssertNil(
            CanvasAnnotation.decode(
                posted: [
                    "kind": "selection", "anchorKind": "unknown", "id": "phase", "text": "Phase",
                ], comment: "change this"))
    }

    func testMarkdownCapturePreservesLiteralSourceAcrossTheWorlds() async throws {
        let source = """
            # **Plan**

            First **formatted** paragraph with `code`.
            A second line.

            > Nested **quoted** paragraph.

            - Outer item
              - Nested `item`

            | Name | State |
            | --- | --- |
            | **Task** | `done` |

            [ref]: https://example.com

            <!-- invisible -->

            A [reference][ref].
            """
        let page = try Page(markdown: source)
        defer { page.close() }
        let messages = try await page.select([
            "h1", "p", "blockquote p", "li li", "td", "p:last-child",
        ])
        XCTAssertEqual(messages.count, 6)
        for message in messages {
            XCTAssertEqual(message["anchorKind"] as? String, "excerpt")
            let excerpt = try XCTUnwrap(message["source"] as? String)
            XCTAssertTrue(source.contains(excerpt), "the excerpt must exist verbatim in source")
            let note = try XCTUnwrap(
                CanvasAnnotation.decode(posted: message, comment: "change this"))
            XCTAssertTrue(CanvasNotes.entry(note, at: Date()).contains("## source "))
        }
        XCTAssertTrue((messages[1]["source"] as? String)?.contains("**formatted**") == true)
        XCTAssertTrue((messages[3]["source"] as? String)?.contains("- Outer item") == true)
    }

    func testCRLFAndBareCRSourceRemainLiteral() async throws {
        for separator in ["\r\n", "\r"] {
            let source = "First **formatted** line." + separator + "Second `line`." + separator
            let page = try Page(markdown: source)
            defer { page.close() }
            let messages = try await page.select(["p"])
            let message = try XCTUnwrap(messages.first)
            let excerpt = try XCTUnwrap(message["source"] as? String)
            XCTAssertEqual(excerpt, source)
        }
    }

    func testRealMermaidNodesAndSubgraphsRemainFindableWhileUnsupportedFamiliesRefuse() async throws
    {
        let source = """
            ```mermaid
            flowchart TD
              subgraph zone[The Zone]
                phase[Ship]
              end
            ```

            ```mermaid
            sequenceDiagram
              Alice->>Bob: Hello
            ```

            ```mermaid
            mindmap
              root((Topic))
                Branch
            ```

            ```mermaid
            pie
              "Alpha": 40
              "Beta": 60
            ```
            """
        let page = try Page(markdown: source)
        defer { page.close() }
        let messages = try await page.select([
            ".cluster .nodeLabel", ".node .nodeLabel",
            "pre.mermaid:nth-of-type(2) text.actor",
            "pre.mermaid:nth-of-type(3) .nodeLabel",
            "pre.mermaid:nth-of-type(4) text.slice",
        ])
        XCTAssertEqual(messages.count, 5)
        let cluster = try XCTUnwrap(
            CanvasAnnotation.decode(posted: messages[0], comment: "boundary"))
        XCTAssertEqual(cluster.mark, .selection(.element(id: "zone", text: "The Zone")))
        let node = try XCTUnwrap(CanvasAnnotation.decode(posted: messages[1], comment: "node"))
        XCTAssertEqual(node.mark, .selection(.element(id: "phase", text: "Ship")))
        for message in messages.dropFirst(2) {
            guard case let .selected(selection) = try CanvasPageSelection.decode(message).get()
            else {
                return XCTFail("unsupported targets must explain their refusal")
            }
            XCTAssertNil(CanvasAnnotation.decode(selection, comment: "change"))
            XCTAssertTrue(CanvasCommentField.quote(for: selection).contains("not anchorable"))
        }
    }

    func testSourceExcerptHeadingRoundTripsNewlinesQuotesAndBackslashes() throws {
        let source = "> **quoted** \"text\" and \\code\r\n"
        let annotation = try XCTUnwrap(
            CanvasAnnotation.decode(
                posted: [
                    "kind": "selection", "anchorKind": "excerpt", "source": source,
                    "text": "quoted text",
                ], comment: "change"))
        let heading = try XCTUnwrap(
            CanvasNotes.headings(in: CanvasNotes.entry(annotation, at: Date())).first)
        let json = String(heading.dropFirst("source ".count))
        let decoded = try JSONDecoder().decode(String.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, source)
    }

    func testMalformedSourceMetadataReportsARefusal() throws {
        let page = try CanvasScriptRuntime()
        page.evaluateFromSwift(
            "document.querySelectorAll('[data-helm-source]')[0].setAttribute('data-helm-source', 'not JSON');"
        )
        page.setTool(.text)
        page.select(inBlockWithText: "First unnamed block", text: "unnamed")
        page.mouse("mouseup", 100, 1240)
        XCTAssertTrue(page.drainExceptions().isEmpty)
        let body = try XCTUnwrap(page.lastPosted)
        guard case let .selected(selection) = try CanvasPageSelection.decode(body).get() else {
            return XCTFail("must report the refusal")
        }
        XCTAssertNil(CanvasAnnotation.decode(selection, comment: "change"))
        XCTAssertTrue(CanvasCommentField.quote(for: selection).contains("not anchorable"))
    }

    func testAnAuthoredMarkdownContainerIDIsPreferredToItsParagraphExcerpt() async throws {
        let page = try Page(
            markdown: "<div id=\"phase\">\n\nFirst **formatted** paragraph.\n\n</div>\n")
        defer { page.close() }
        let messages = try await page.select(["p"])
        let note = try XCTUnwrap(CanvasAnnotation.decode(posted: messages[0], comment: "change"))
        XCTAssertEqual(
            note.mark, .selection(.element(id: "phase", text: "First formatted paragraph.")))
    }

    func testIdlessHTMLAndMultiBlockMarkdownCannotWriteMisleadingNotes() async throws {
        let stub = try CanvasScriptRuntime()
        stub.asHTMLArtifact()
        stub.evaluateFromSwift(
            "document.querySelectorAll('[id]').forEach(function(node) { node.removeAttribute('id'); });"
        )
        stub.setTool(.text)
        stub.select(inBlockWithText: "First unnamed block", text: "unnamed")
        stub.mouse("mouseup", 100, 1240)
        XCTAssertNil(
            CanvasAnnotation.decode(posted: try XCTUnwrap(stub.lastPosted), comment: "change"))
        XCTAssertEqual(stub.lastPosted?["anchorKind"] as? String, "unanchored")

        let page = try Page(markdown: "First **paragraph**.\n\nSecond `paragraph`.\n")
        defer { page.close() }
        let messages = try await page.select(["#content"])
        XCTAssertNil(CanvasAnnotation.decode(posted: messages[0], comment: "change"))
        XCTAssertEqual(messages[0]["anchorKind"] as? String, "unanchored")
    }

    private final class Page: NSObject, WKScriptMessageHandler {
        private var webView: WKWebView!
        private var messages: [[String: Any]] = []
        private var loaded = false

        init(markdown: String) throws {
            super.init()
            let controller = WKUserContentController()
            controller.add(
                self, contentWorld: CanvasFileCoordinator.bridgeWorld, name: "helmCanvas")
            controller.add(self, name: "ready")
            controller.addUserScript(
                WKUserScript(
                    source: try XCTUnwrap(CanvasHTML.vendoredMarked()),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true))
            if markdown.contains("```mermaid") {
                controller.addUserScript(
                    WKUserScript(
                        source: try XCTUnwrap(CanvasHTML.vendoredMermaid()),
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true))
            }
            controller.addUserScript(
                WKUserScript(
                    source: CanvasHTML.annotationScript(), injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true, in: CanvasFileCoordinator.bridgeWorld))
            controller.addUserScript(
                WKUserScript(
                    source: "window.webkit.messageHandlers.ready.postMessage('ready');",
                    injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController = controller
            webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
            webView.loadHTMLString(
                CanvasHTML.documentPage(markdown: markdown, theme: .light), baseURL: nil)
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            if message.name == "ready" { loaded = true }
            if let body = message.body as? [String: Any] { messages.append(body) }
        }

        func select(_ selectors: [String]) async throws -> [[String: Any]] {
            try await wait { self.loaded }
            for selector in selectors {
                let count = messages.count
                webView.evaluateJavaScript(
                    """
                    (function() {
                      \(CanvasHTML.setMarkTool(.text, theme: .light))
                      var deadline = Date.now() + 10000;
                      function markWhenReady() {
                      var node = document.querySelector(\(CanvasHTML.jsString(selector)));
                      if (!node) {
                        if (Date.now() < deadline) { setTimeout(markWhenReady, 10); }
                        return;
                      }
                      var range = document.createRange(); range.selectNodeContents(node);
                      var selection = document.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                      document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
                      }
                      markWhenReady();
                    })();
                    """, in: nil, in: CanvasFileCoordinator.bridgeWorld, completionHandler: { _ in }
                )
                try await wait { self.messages.count > count }
            }
            return messages
        }

        // Poll an observable with a deadline; elapsed time alone never passes an assertion.
        private func wait(_ ready: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(ready(), "WebKit did not report within the deadline")
            if !ready() { throw NSError(domain: "CanvasSourceAnchorTests", code: 1) }
        }

        func close() {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
        }
    }
}
