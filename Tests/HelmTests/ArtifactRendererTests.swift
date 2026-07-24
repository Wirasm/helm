import SwiftUI
import XCTest
@testable import Helm

/// The artifact pane's text routing, exercised as pure functions — no views,
/// no files, no GUI. Markdown prose stays raw in its segment (the pane renders
/// it with `MarkdownText` under the document theme — see MarkdownThemeTests
/// for the typography); only plain text is pre-styled here.
final class ArtifactRendererTests: XCTestCase {
    private let mdURL = URL(fileURLWithPath: "/tmp/plan.md")
    private let logURL = URL(fileURLWithPath: "/tmp/build.log")

    // MARK: File-kind routing

    func testMarkdownExtensionsDetected() {
        XCTAssertTrue(ArtifactRenderer.isMarkdown(URL(fileURLWithPath: "/a/plan.md")))
        XCTAssertTrue(ArtifactRenderer.isMarkdown(URL(fileURLWithPath: "/a/PLAN.MD")))
        XCTAssertTrue(ArtifactRenderer.isMarkdown(URL(fileURLWithPath: "/a/notes.markdown")))
        XCTAssertFalse(ArtifactRenderer.isMarkdown(URL(fileURLWithPath: "/a/build.log")))
        XCTAssertFalse(ArtifactRenderer.isMarkdown(URL(fileURLWithPath: "/a/script.sh")))
    }

    func testHTMLExtensionsDetected() {
        XCTAssertTrue(ArtifactRenderer.isHTML(URL(fileURLWithPath: "/a/page.html")))
        XCTAssertTrue(ArtifactRenderer.isHTML(URL(fileURLWithPath: "/a/PAGE.HTM")))
        XCTAssertFalse(ArtifactRenderer.isHTML(URL(fileURLWithPath: "/a/plan.md")))
    }

    // MARK: Plain text

    func testPlainTextRendersVerbatimAndMonospaced() {
        let raw = "line one\n  indented # not a heading\nline three"
        let rendered = ArtifactRenderer.renderPlainText(raw)

        XCTAssertEqual(String(rendered.characters), raw, "plain text must not be reflowed")
        for run in rendered.runs {
            XCTAssertEqual(run.font, ArtifactRenderer.monoFont)
        }
    }

    func testUnparseableContentFallsBackToPlainText() {
        // Pins the fallback path's contract: never throw, never drop content.
        let raw = "just some text"
        let rendered = ArtifactRenderer.renderPlainText(raw)
        XCTAssertEqual(String(rendered.characters), raw)
    }

    // MARK: Segment routing

    func testMarkdownProseStaysRawInItsSegment() {
        // The pane renders markdown with the themed block renderer — the raw
        // source (headings, fences, and all) must survive the routing intact.
        let raw = "# Title\n\n- item `code`"
        let segments = ArtifactRenderer.renderSegments(raw, from: mdURL)

        XCTAssertEqual(segments.count, 1)
        guard case let .markdown(markdown) = segments[0] else {
            return XCTFail("expected a single markdown segment, got \(segments)")
        }
        XCTAssertEqual(markdown, raw)
    }

    func testMarkdownWithMermaidRendersInterleavedSegments() {
        let raw = "**Caption**\n\n```mermaid\ngraph TD; A-->B\n```\n\nAfter."
        let segments = ArtifactRenderer.renderSegments(raw, from: mdURL)

        XCTAssertEqual(segments.count, 3)
        guard case let .markdown(before) = segments[0],
              case let .mermaid(diagram) = segments[1],
              case let .markdown(after) = segments[2]
        else {
            return XCTFail("expected markdown/mermaid/markdown, got \(segments)")
        }
        XCTAssertEqual(before.trimmingCharacters(in: .whitespacesAndNewlines), "**Caption**")
        XCTAssertEqual(diagram, "graph TD; A-->B")
        XCTAssertEqual(after.trimmingCharacters(in: .whitespacesAndNewlines), "After.")
    }

    func testNonMarkdownStaysASingleMonospacedTextSegment() {
        // A mermaid fence in a .log file is just text — no islands.
        let raw = "```mermaid\ngraph TD; A-->B\n```"
        let segments = ArtifactRenderer.renderSegments(raw, from: logURL)

        XCTAssertEqual(segments.count, 1)
        guard case let .text(text) = segments[0] else {
            return XCTFail("expected a single text segment, got \(segments)")
        }
        XCTAssertEqual(String(text.characters), raw)
        for run in text.runs {
            XCTAssertEqual(run.font, ArtifactRenderer.monoFont)
        }
    }
}
