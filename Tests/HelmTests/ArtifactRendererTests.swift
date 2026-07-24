import SwiftUI
import XCTest
@testable import Helm

/// The artifact pane's text rendering, exercised as pure functions — no views,
/// no files, no GUI. Font expectations compare against ArtifactRenderer's own
/// typography constants so a deliberate style change doesn't break tests.
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

    func testPlainTextRendersVerbatimAndMonospaced() {
        let raw = "line one\n  indented # not a heading\nline three"
        let rendered = ArtifactRenderer.render(raw, from: logURL)

        XCTAssertEqual(String(rendered.characters), raw, "plain text must not be reflowed")
        for run in rendered.runs {
            XCTAssertEqual(run.font, ArtifactRenderer.monoFont)
        }
    }

    // MARK: Markdown block styling

    func testHeadingsGetHeadingFonts() {
        let rendered = ArtifactRenderer.render("# Title\n\nBody text.", from: mdURL)

        XCTAssertEqual(
            font(over: "Title", in: rendered),
            ArtifactRenderer.headingFont(level: 1)
        )
        XCTAssertEqual(font(over: "Body text.", in: rendered), ArtifactRenderer.bodyFont)
    }

    func testBlocksAreSeparatedByBlankLines() {
        let rendered = ArtifactRenderer.render("# Title\n\nFirst.\n\nSecond.", from: mdURL)

        // The parser strips inter-block newlines; the renderer must reinsert
        // them or the whole document lands on one line.
        XCTAssertEqual(String(rendered.characters), "Title\n\nFirst.\n\nSecond.")
    }

    func testCodeBlockIsMonospaced() {
        let markdown = """
        Intro.

        ```swift
        let x = 1
        ```
        """
        let rendered = ArtifactRenderer.render(markdown, from: mdURL)

        XCTAssertEqual(font(over: "let x = 1", in: rendered), ArtifactRenderer.monoFont)
        XCTAssertEqual(font(over: "Intro.", in: rendered), ArtifactRenderer.bodyFont)
    }

    func testInlineCodeIsMonospaced() {
        let rendered = ArtifactRenderer.render("Run `swift build` now.", from: mdURL)

        XCTAssertEqual(font(over: "swift build", in: rendered), ArtifactRenderer.monoFont)
        XCTAssertEqual(font(over: "Run ", in: rendered), ArtifactRenderer.bodyFont)
    }

    func testUnorderedListGetsBullets() {
        let rendered = ArtifactRenderer.render("- alpha\n- beta", from: mdURL)

        XCTAssertEqual(String(rendered.characters), "•  alpha\n•  beta")
    }

    func testOrderedListGetsNumbers() {
        let rendered = ArtifactRenderer.render("1. first\n2. second", from: mdURL)

        XCTAssertEqual(String(rendered.characters), "1. first\n2. second")
    }

    // MARK: Segment routing

    func testMarkdownWithMermaidRendersInterleavedSegments() {
        let raw = "**Caption**\n\n```mermaid\ngraph TD; A-->B\n```\n\nAfter."
        let segments = ArtifactRenderer.renderSegments(raw, from: mdURL)

        XCTAssertEqual(segments.count, 3)
        guard case let .text(before) = segments[0],
              case let .mermaid(diagram) = segments[1],
              case let .text(after) = segments[2]
        else {
            return XCTFail("expected text/mermaid/text, got \(segments)")
        }
        XCTAssertEqual(String(before.characters), "Caption")
        XCTAssertEqual(diagram, "graph TD; A-->B")
        XCTAssertEqual(String(after.characters), "After.")
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

    func testHTMLExtensionsDetected() {
        XCTAssertTrue(ArtifactRenderer.isHTML(URL(fileURLWithPath: "/a/page.html")))
        XCTAssertTrue(ArtifactRenderer.isHTML(URL(fileURLWithPath: "/a/PAGE.HTM")))
        XCTAssertFalse(ArtifactRenderer.isHTML(URL(fileURLWithPath: "/a/plan.md")))
    }

    func testUnparseableContentFallsBackToPlainText() {
        // Foundation's parser accepts almost anything, so this mainly pins the
        // fallback path's contract: never throw, never drop content.
        let raw = "just some text"
        let rendered = ArtifactRenderer.renderPlainText(raw)
        XCTAssertEqual(String(rendered.characters), raw)
    }

    // MARK: Helper

    /// Font of the run covering `substring` (nil when absent or spanning runs
    /// with differing fonts — both failures for our assertions).
    private func font(over substring: String, in rendered: AttributedString) -> Font? {
        guard let range = rendered.range(of: substring) else {
            XCTFail("'\(substring)' not found in rendered output")
            return nil
        }
        var fonts = Set<Font?>()
        for run in rendered[range].runs {
            fonts.insert(run.font)
        }
        XCTAssertEqual(fonts.count, 1, "'\(substring)' spans differing fonts")
        return fonts.first ?? nil
    }
}
