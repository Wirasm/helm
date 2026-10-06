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

    /// A list's numbers end in one column, so every item's text starts in the same one: "9."
    /// gets a blank before it when the list reaches "10.", and a later paragraph of an item is
    /// as wide.
    func testAListsMarkersEndInOneColumn() {
        let items = (1...10).map { "\($0). item \($0)" }.joined(separator: "\n")
        let markers = ChatMarkdown.blocks(items + "\n\n    more of ten").compactMap { block in
            if case let .item(_, marker) = block.kind { marker } else { nil }
        }
        XCTAssertEqual(markers.first, " 1.")
        XCTAssertEqual(markers[8], " 9.")
        XCTAssertEqual(markers[9], "10.")
        XCTAssertEqual(markers.last, "   ", "a later paragraph of item 10")
        XCTAssertEqual(
            ChatMarkdown.blocks("- a\n  1. x\n  2. y").compactMap { block in
                if case let .item(_, marker) = block.kind { marker } else { nil }
            },
            ["•", "1.", "2."], "each list by its own widest marker")
    }

    /// A real reply (archon-7fba, 2026-10-05): two tables under their headings, every row as
    /// many cells as the header, an empty cell kept.
    func testARealReplysTablesAreTables() throws {
        let reply = """
            The main lanes are the standalone-core tracks under #2791.

            ## Persistence lane (#3640, then #3643)

            | Step | What it does | Status |
            |---|---|---|
            | #3640 PR 1 (#3682) | Run operations use the stores they're given instead of reaching for the database directly. | Open, and CI is running. I'll ask you before merging. |
            | #3640 PR 2 | Runs started from the CLI stop creating a chat conversation as a side effect. | Its run launches as soon as #3682 merges. |

            ## Providers lane (#3638, then #3642, then #3645)

            | Step | What it does | Status |
            |---|---|---|
            | #3638 PR 1 (#3687) | | Merged. |
            | #3638 PR 2 (#3767) | Workflows can use providers the host registers. | A takeover agent is updating it. |
            """
        let tables = ChatMarkdown.blocks(reply).compactMap { block in
            if case let .table(rows, header) = block.kind { (rows, header) } else { nil }
        }
        XCTAssertEqual(tables.count, 2)
        for (rows, header) in tables {
            XCTAssertTrue(header)
            XCTAssertEqual(rows.map(\.count), [3, 3, 3])
        }
        XCTAssertEqual(plain(tables[1].0[1][1]), "", "the empty cell stays a cell")
    }

    /// Two paragraphs in a row stay two blocks, and plain text is one paragraph.
    func testParagraphsStayApart() {
        XCTAssertEqual(ChatMarkdown.blocks("one\n\ntwo").map { plain($0.text) }, ["one", "two"])
        XCTAssertEqual(ChatMarkdown.blocks("just text").map(\.kind), [.paragraph])
    }
}
