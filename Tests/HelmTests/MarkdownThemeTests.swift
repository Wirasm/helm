import SwiftUI
import XCTest
@testable import Helm

/// The shared typographic system behind both markdown surfaces — chat posts
/// and artifact-pane documents. Pure value checks: fonts per block type and
/// the paragraph-spacing rules, per profile. No views, no GUI.
final class MarkdownThemeTests: XCTestCase {
    // MARK: Chat scale

    func testChatTypeScale() {
        let theme = MarkdownTheme.chat
        XCTAssertEqual(theme.bodyFont, .system(size: 14))
        XCTAssertEqual(theme.headingFont(level: 1), .system(size: 18, weight: .semibold))
        XCTAssertEqual(theme.headingFont(level: 2), .system(size: 16, weight: .semibold))
        XCTAssertEqual(theme.headingFont(level: 3), .system(size: 14, weight: .semibold))
        XCTAssertEqual(theme.inlineCodeFont, .system(size: 13, design: .monospaced))
        XCTAssertEqual(theme.codeBlockFont, .system(size: 12.5, design: .monospaced))
        XCTAssertEqual(theme.lineSpacing, 4)
        XCTAssertEqual(theme.blockSpacing, 8)
        XCTAssertEqual(theme.headingSpaceAbove, 10)
        XCTAssertEqual(theme.listItemSpacing, 4)
        XCTAssertNil(theme.measure, "chat bubbles size themselves — no measure cap")
        XCTAssertFalse(theme.ruleBelowH1)
    }

    // MARK: Document scale

    func testDocumentTypeScale() {
        let theme = MarkdownTheme.document
        XCTAssertEqual(theme.bodyFont, .system(size: 15))
        XCTAssertEqual(theme.headingFont(level: 1), .system(size: 24, weight: .bold))
        XCTAssertEqual(theme.headingFont(level: 2), .system(size: 19, weight: .semibold))
        XCTAssertEqual(theme.headingFont(level: 3), .system(size: 16, weight: .semibold))
        XCTAssertEqual(theme.inlineCodeFont, .system(size: 14, design: .monospaced))
        XCTAssertEqual(theme.codeBlockFont, .system(size: 13.5, design: .monospaced))
        XCTAssertEqual(theme.lineSpacing, 5)
        XCTAssertEqual(theme.blockSpacing, 10)
        XCTAssertEqual(theme.headingSpaceAbove, 14)
        XCTAssertEqual(theme.measure, 760, "long-line reading needs a capped measure")
        XCTAssertTrue(theme.ruleBelowH1)
    }

    func testDocumentScaleIsLargerThanChat() {
        // The pane is a reading surface; its whole scale sits above chat's.
        XCTAssertGreaterThan(MarkdownTheme.document.bodySize, MarkdownTheme.chat.bodySize)
        XCTAssertGreaterThan(
            MarkdownTheme.document.headingSizes[0],
            MarkdownTheme.chat.headingSizes[0]
        )
        XCTAssertGreaterThan(
            MarkdownTheme.document.codeBlockSize,
            MarkdownTheme.chat.codeBlockSize
        )
    }

    // MARK: Heading level clamping

    func testDeepHeadingLevelsReuseTheSmallestHeadingFont() {
        for theme in [MarkdownTheme.chat, MarkdownTheme.document] {
            XCTAssertEqual(theme.headingFont(level: 4), theme.headingFont(level: 3))
            XCTAssertEqual(theme.headingFont(level: 6), theme.headingFont(level: 3))
        }
    }

    // MARK: Font per block type

    func testFontForBlockMatchesBlockType() {
        let theme = MarkdownTheme.chat
        XCTAssertEqual(
            theme.font(for: .heading(level: 2, text: "Why")),
            theme.headingFont(level: 2)
        )
        XCTAssertEqual(theme.font(for: .paragraph("prose")), theme.bodyFont)
        XCTAssertEqual(theme.font(for: .listItem(marker: "•", text: "item")), theme.bodyFont)
        XCTAssertEqual(
            theme.font(for: .code(language: "swift", code: "let x = 1")),
            theme.codeBlockFont
        )
    }

    // MARK: Spacing rules

    func testFirstBlockGetsNoSpaceAbove() {
        let theme = MarkdownTheme.chat
        XCTAssertEqual(theme.spacing(above: .paragraph("p"), after: nil), 0)
        XCTAssertEqual(theme.spacing(above: .heading(level: 1, text: "t"), after: nil), 0)
    }

    func testHeadingsGetTheirOwnSpaceAbove() {
        for theme in [MarkdownTheme.chat, MarkdownTheme.document] {
            XCTAssertEqual(
                theme.spacing(above: .heading(level: 2, text: "t"), after: .paragraph("p")),
                theme.headingSpaceAbove
            )
        }
    }

    func testConsecutiveListItemsAreTighterThanParagraphs() {
        let theme = MarkdownTheme.chat
        let item = PostMarkdown.Block.listItem(marker: "•", text: "a")
        XCTAssertEqual(theme.spacing(above: item, after: item), theme.listItemSpacing)
        XCTAssertLessThan(theme.listItemSpacing, theme.blockSpacing)
        // A list that starts after prose separates like a paragraph.
        XCTAssertEqual(theme.spacing(above: item, after: .paragraph("p")), theme.blockSpacing)
    }

    func testParagraphsAndCodeBlocksUseParagraphSpacing() {
        let theme = MarkdownTheme.document
        XCTAssertEqual(
            theme.spacing(above: .paragraph("b"), after: .paragraph("a")),
            theme.blockSpacing
        )
        XCTAssertEqual(
            theme.spacing(above: .code(language: nil, code: "x"), after: .paragraph("a")),
            theme.blockSpacing
        )
        XCTAssertEqual(
            theme.spacing(above: .paragraph("after"), after: .code(language: nil, code: "x")),
            theme.blockSpacing
        )
    }
}
