import WebKit
import XCTest

@testable import Helm

@MainActor
final class CanvasSourceAnchorTests: XCTestCase {
    func testSubgraphUsesItsAuthoredIdentifier() throws {
        let note = try XCTUnwrap(
            CanvasAnnotation.decode(
                posted: [
                    "kind": "selection", "anchorKind": "mermaid", "rendererRole": "cluster",
                    "id": "mermaid-0-zone", "text": "The Zone",
                ], comment: "change this boundary"))
        XCTAssertEqual(note.mark, .selection(.element(id: "zone", text: "The Zone")))
    }

    func testUnsupportedDiagramCannotPersistAQuote() throws {
        let body: [String: Any] = [
            "kind": "selection", "anchorKind": "mermaid", "rendererRole": "node", "id": "mermaid-0",
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

    func testUnknownMermaidRendererRoleCannotBecomeAnAuthoredID() {
        XCTAssertNil(
            CanvasAnnotation.decode(
                posted: [
                    "kind": "selection", "anchorKind": "mermaid", "rendererRole": "unknown",
                    "id": "mermaid-0-flowchart-phase-0", "text": "Phase",
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
        let page = try CanvasSourceAnchorPage(markdown: source)
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
            let page = try CanvasSourceAnchorPage(markdown: source)
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
        let page = try CanvasSourceAnchorPage(markdown: source)
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
        let selected = "quoted \"text\"\nand \\code"
        let annotation = try XCTUnwrap(
            CanvasAnnotation.decode(
                posted: [
                    "kind": "selection", "anchorKind": "excerpt", "source": source,
                    "text": selected,
                ], comment: "change"))
        let heading = try XCTUnwrap(
            CanvasNotes.headings(in: CanvasNotes.entry(annotation, at: Date())).first)
        let values = String(heading.dropFirst("source ".count)).components(separatedBy: " text ")
        XCTAssertEqual(values.count, 2, "the heading must retain source and selected words")
        guard values.count == 2 else { return }
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(values[0].utf8)), source)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(values[1].utf8)), selected)
    }

    private let styledMermaidCases = [
        (
            "flowchart TD\nphase[Ship]:::cluster\nclassDef cluster fill:red",
            ".node.cluster", "phase"
        ),
        (
            "stateDiagram-v2\nidle --> running\nclassDef cluster fill:red\nclass idle cluster",
            ".node.cluster", "idle"
        ),
        (
            "classDiagram\nclass Animal\ncssClass \"Animal\" cluster",
            ".node.cluster", "Animal"
        ),
        (
            "erDiagram\nCUSTOMER ||--o{ ORDER : places\nclassDef cluster fill:red\nclass CUSTOMER cluster",
            ".node.cluster", "CUSTOMER"
        ),
        (
            "flowchart TD\nsubgraph flowchart-phase-0[Zone]\nphase[Ship]\nend",
            ".cluster", "flowchart-phase-0"
        ),
        (
            "flowchart TD\nsubgraph zone[Zone]\nphase[Ship]\nend\nclass zone node",
            ".cluster", "zone"
        ),
        (
            "flowchart TD\nsubgraph state-phase-0[Zone]\nphase[Ship]\nend\nclass state-phase-0 node",
            ".cluster", "state-phase-0"
        ),
        (
            "stateDiagram-v2\nstate Composite {\nidle --> running\n}\nclass Composite node",
            ".statediagram-cluster", "Composite"
        ),
        (
            "stateDiagram-v2\nstate Composite {\nidle --> running\n}\nclass Composite cluster",
            ".statediagram-cluster", "Composite"
        ),
        (
            "classDiagram\nnamespace Namespace {\nclass Animal\n}",
            ".cluster", "Namespace"
        ),
    ]

    func testMermaidClusterClassOnNodesDoesNotHideTheirSourceIdentifiers() async throws {
        for (diagram, selector, identifier) in styledMermaidCases {
            let page = try CanvasSourceAnchorPage(markdown: "```mermaid\n\(diagram)\n```\n")
            defer { page.close() }
            let messages = try await page.select([selector])
            guard let note = CanvasAnnotation.decode(posted: messages[0], comment: "change") else {
                XCTFail("must anchor \(identifier)"); continue
            }
            guard case let .selection(.element(id, _)) = note.mark else {
                return XCTFail("expected an authored Mermaid identifier for \(identifier)")
            }
            XCTAssertEqual(id, identifier, diagram)
        }
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
        let page = try CanvasSourceAnchorPage(
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

        let page = try CanvasSourceAnchorPage(
            markdown: "First **paragraph**.\n\nSecond `paragraph`.\n")
        defer { page.close() }
        let messages = try await page.select(["#content"])
        XCTAssertNil(CanvasAnnotation.decode(posted: messages[0], comment: "change"))
        XCTAssertEqual(messages[0]["anchorKind"] as? String, "unanchored")
    }

}
