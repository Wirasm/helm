import SwiftUI
import XCTest

@testable import Helm

/// The typographic system behind the room log's markdown. Pure value checks:
/// fonts per block type and the paragraph-spacing rules. No views, no GUI.
/// (The canvas's document scale is CSS now — see CanvasHTMLTests.)
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
    }

    // MARK: Heading level clamping

    func testDeepHeadingLevelsReuseTheSmallestHeadingFont() {
        let theme = MarkdownTheme.chat
        XCTAssertEqual(theme.headingFont(level: 4), theme.headingFont(level: 3))
        XCTAssertEqual(theme.headingFont(level: 6), theme.headingFont(level: 3))
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
        let theme = MarkdownTheme.chat
        XCTAssertEqual(
            theme.spacing(above: .heading(level: 2, text: "t"), after: .paragraph("p")),
            theme.headingSpaceAbove
        )
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
        let theme = MarkdownTheme.chat
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
