import Foundation
import XCTest

@testable import PocketKit

/// A reply's markdown as the blocks Pocket draws, from Apple's parser.
final class ChatMarkdownTests: XCTestCase {
    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    /// Each block kind an agent writes, in order: its kind and its text, line breaks as written.
    func testEachBlockAnAgentWritesIsItsKind() {
        let blocks = ChatMarkdown.blocks(
            """
            ## Result
            First line
            second line.

            - one **bold**
              1. nested a
              2. nested b

            ```swift
            let x = 1
            ```

            > quoted

            ---
            """)
        XCTAssertEqual(
            blocks.map(\.kind),
            [
                .heading(level: 2), .paragraph, .item(depth: 1, marker: "•"),
                .item(depth: 2, marker: "1."), .item(depth: 2, marker: "2."), .code, .quote, .rule,
            ])
        XCTAssertEqual(
            blocks.map { plain($0.text) },
            [
                "Result", "First line\nsecond line.", "one bold", "nested a", "nested b",
                "let x = 1",
                "quoted", "⸻",
            ])
        let bold = blocks[2].text.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertNotNil(bold, "inline runs stay for the drawing to style")
    }

    /// A table is its rows of cells, the header first, every row as wide as its widest.
    func testATableIsItsRowsOfCells() throws {
        let blocks = ChatMarkdown.blocks(
            """
            | Part | State |
            |------|-------|
            | lint | PASS |
            | swift | **FAIL** |

            after
            """)
        XCTAssertEqual(blocks.count, 2)
        guard case let .table(rows, header) = blocks[0].kind else {
            return XCTFail("\(blocks[0].kind)")
        }
        XCTAssertTrue(header)
        XCTAssertEqual(
            rows.map { $0.map(plain) }, [["Part", "State"], ["lint", "PASS"], ["swift", "FAIL"]])
        XCTAssertEqual(blocks[1].kind, .paragraph)
    }

    /// A list item of two paragraphs is marked once: the second sits under the first's text.
    func testALooseListItemIsMarkedOnce() {
        let blocks = ChatMarkdown.blocks("1. Step one\n\n   Detail\n\n2. Step two")
        XCTAssertEqual(
            blocks.map(\.kind),
            [
                .item(depth: 1, marker: "1."), .item(depth: 1, marker: "  "),
                .item(depth: 1, marker: "2."),
            ])
        XCTAssertEqual(
            ChatMarkdown.blocks("- a\n\n  - b\n\n  more of a\n- c").map(\.kind),
            [
                .item(depth: 1, marker: "•"), .item(depth: 2, marker: "•"),
                .item(depth: 1, marker: " "), .item(depth: 1, marker: "•"),
            ],
            "a paragraph after a nested list is still its item's")
    }

    /// Two paragraphs in a row stay two blocks, and plain text is one paragraph.
    func testParagraphsStayApart() {
        XCTAssertEqual(ChatMarkdown.blocks("one\n\ntwo").map { plain($0.text) }, ["one", "two"])
        XCTAssertEqual(ChatMarkdown.blocks("just text").map(\.kind), [.paragraph])
    }
}
