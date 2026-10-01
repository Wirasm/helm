import XCTest

@testable import Helm

/// Cross-runtime pairing for MermaidAnchor.swift and canvas-annotation.js. The vendor renders,
/// the shipped script captures, Swift reduces, the sidecar round-trips, and hover must find it.
/// Each label also appears in plain prose, so a wrong ID cannot pass through quote fallback.
@MainActor
final class CanvasHoverIntegrationTests: XCTestCase {
    private let diagrams = [
        ("flowchart TD\nphase[Ship]", ".node .nodeLabel", "phase"),
        ("classDiagram\nclass Animal", ".node", "Animal"),
        ("stateDiagram-v2\nidle --> running", ".node", "idle"),
        ("erDiagram\nCUSTOMER ||--o{ ORDER : places", ".node", "CUSTOMER"),
        ("flowchart TD\nsubgraph zone[Zone]\nphase[Ship]\nend", ".cluster .nodeLabel", "zone"),
        ("classDiagram\nnamespace Namespace {\nclass Animal\n}", ".cluster", "Namespace"),
        (
            "stateDiagram-v2\nstate Composite {\nidle --> running\n}", ".statediagram-cluster",
            "Composite"
        ),
        (
            "flowchart TD\nsubgraph flowchart-phase-0[Zone]\nphase[Ship]\nend", ".cluster",
            "flowchart-phase-0"
        ),
    ]

    func testEverySupportedMermaidFamilyAndGroupCapturesThenHoversWithSwiftProducedID() async throws
    {
        for (diagram, selector, expectedID) in diagrams {
            let page = try CanvasSourceAnchorPage(markdown: "```mermaid\n\(diagram)\n```\n")
            defer { page.close() }
            let messages = try await page.select([selector])
            let body = try XCTUnwrap(messages.first)
            let renderedID = try XCTUnwrap(body["id"] as? String)
            let role = try XCTUnwrap(
                MermaidAnchor.RendererRole(rawValue: try XCTUnwrap(body["rendererRole"] as? String))
            )
            XCTAssertEqual(MermaidAnchor.sourceIdentifier(in: renderedID, role: role), expectedID)
            let annotation = try XCTUnwrap(CanvasAnnotation.decode(posted: body, comment: "change"))
            guard case let .selection(.element(id, _)) = annotation.mark else {
                XCTFail("Expected a Mermaid source identifier"); continue
            }
            XCTAssertEqual(id, expectedID)
            let selected = try XCTUnwrap(body["text"] as? String)
            try await page.repeatLabel(selected)
            let missingID = try XCTUnwrap(
                CanvasAnnotation.decode(
                    posted: [
                        "kind": "selection", "anchorKind": "element", "id": "missing-id-probe",
                        "text": selected,
                    ], comment: "probe the fallback"))
            let fallbackPainted = try await page.hover(missingID)
            XCTAssertFalse(fallbackPainted, "Repeated labels must make quote fallback ambiguous")
            let painted = try await page.hover(annotation)
            XCTAssertTrue(painted, "Capture and lookup disagreed on \(expectedID) in \(diagram)")
        }
    }

    func testCapturedMarkdownExcerptRoundTripsAndHovers() async throws {
        let source = "First **formatted** paragraph with `code`.\r\nSecond line.\r\n"
        let page = try CanvasSourceAnchorPage(markdown: source)
        defer { page.close() }
        let messages = try await page.select(["strong"])
        let annotation = try XCTUnwrap(
            CanvasAnnotation.decode(posted: try XCTUnwrap(messages.first), comment: "change"))
        let heading = CanvasNotes.describe(annotation.mark)
        XCTAssertEqual(CanvasNotes.mark(in: heading), annotation.mark)
        let painted = try await page.hover(annotation)
        XCTAssertTrue(painted)
    }

    func testExcerptHeadingWithLiteralDelimiterTextIsLossless() {
        let mark = CanvasAnnotation.Mark.selection(
            .excerpt(
                source: "A literal \" text \" delimiter, \\slash and **words**.\r\n", text: "words")
        )
        let heading = CanvasNotes.describe(mark)
        XCTAssertEqual(CanvasNotes.mark(in: heading), mark)
        XCTAssertEqual(CanvasNotes.mark(in: heading).map(CanvasNotes.describe), heading)
        XCTAssertNil(CanvasNotes.mark(in: "source \"source-only historical heading\""))
        XCTAssertNil(CanvasNotes.mark(in: "source \"source\" text \"\""))
    }

    func testChangedOrDuplicateSourceIsNotRecoveredFromUnrelatedMatchingWords() async throws {
        let old = try XCTUnwrap(
            CanvasAnnotation.decode(
                posted: [
                    "kind": "selection", "anchorKind": "excerpt", "source": "Old **words**.\n",
                    "text": "words",
                ], comment: "change"))
        let changed = try CanvasSourceAnchorPage(markdown: "New **words**.\n")
        defer { changed.close() }
        _ = try await changed.select(["strong"])
        let changedPainted = try await changed.hover(old)
        XCTAssertFalse(changedPainted)

        let source = "Same **words**.\n\n"
        let duplicate = try CanvasSourceAnchorPage(markdown: source + source)
        defer { duplicate.close() }
        let messages = try await duplicate.select(["strong", "p:last-of-type strong"])
        XCTAssertEqual(messages[0]["source"] as? String, messages[1]["source"] as? String)
        let annotation = try XCTUnwrap(
            CanvasAnnotation.decode(posted: try XCTUnwrap(messages.first), comment: "change"))
        let duplicatePainted = try await duplicate.hover(annotation)
        XCTAssertFalse(duplicatePainted)
    }
}
