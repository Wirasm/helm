import XCTest

@testable import Helm

/// The block splitter behind the room-log markdown rendering. Agent reports mix
/// headings, lists, fences, and prose — the splitter must carve those apart so
/// each block renders with its own type treatment (and raw `##` never reaches
/// the screen). Pure function, no SwiftUI.
final class PostMarkdownTests: XCTestCase {
    func testPlainTextIsOneParagraph() {
        XCTAssertEqual(
            PostMarkdown.blocks(from: "just a plain sentence"),
            [.paragraph("just a plain sentence")]
        )
    }

    func testBlankLinesSeparateParagraphsAndInnerNewlinesSurvive() {
        let text = "first line\nstill first paragraph\n\nsecond paragraph"
        XCTAssertEqual(
            PostMarkdown.blocks(from: text),
            [
                .paragraph("first line\nstill first paragraph"),
                .paragraph("second paragraph"),
            ]
        )
    }

    func testHeadingsSplitByLevel() {
        let text = "## Why\nbecause\n### Details"
        XCTAssertEqual(
            PostMarkdown.blocks(from: text),
            [
                .heading(level: 2, text: "Why"),
                .paragraph("because"),
                .heading(level: 3, text: "Details"),
            ]
        )
    }

    func testHashesWithoutSpaceOrTextAreNotHeadings() {
        // Neither a bare marker nor a #hashtag is a heading.
        XCTAssertEqual(PostMarkdown.blocks(from: "##"), [.paragraph("##")])
        XCTAssertEqual(PostMarkdown.blocks(from: "#tag"), [.paragraph("#tag")])
        // Seven hashes exceed markdown's six levels.
        XCTAssertEqual(PostMarkdown.blocks(from: "####### deep"), [.paragraph("####### deep")])
    }

    func testUnorderedAndOrderedListItems() {
        let text = "- alpha\n* beta\n1. first\n2) second"
        XCTAssertEqual(
            PostMarkdown.blocks(from: text),
            [
                .listItem(marker: "•", text: "alpha"),
                .listItem(marker: "•", text: "beta"),
                .listItem(marker: "1.", text: "first"),
                .listItem(marker: "2.", text: "second"),
            ]
        )
    }

    func testDashWithoutSpaceAndBoldStarsAreNotListItems() {
        XCTAssertEqual(PostMarkdown.blocks(from: "-not a list"), [.paragraph("-not a list")])
        XCTAssertEqual(PostMarkdown.blocks(from: "**bold** lead"), [.paragraph("**bold** lead")])
    }

    func testCodeFenceWithLanguage() {
        let text = "before\n```swift\nlet x = 1\n\nlet y = 2\n```\nafter"
        XCTAssertEqual(
            PostMarkdown.blocks(from: text),
            [
                .paragraph("before"),
                .code(language: "swift", code: "let x = 1\n\nlet y = 2"),
                .paragraph("after"),
            ]
        )
    }

    func testFenceSwallowsMarkdownLookalikesInside() {
        // `## heading` and `- item` inside a fence are code, not blocks.
        let text = "```\n## not a heading\n- not a list\n```"
        XCTAssertEqual(
            PostMarkdown.blocks(from: text),
            [.code(language: nil, code: "## not a heading\n- not a list")]
        )
    }

    func testUnterminatedFenceStillYieldsACodeBlock() {
        // Agents get cut off mid-report — the tail must render as code, not vanish.
        let text = "report:\n```sh\nswift build"
        XCTAssertEqual(
            PostMarkdown.blocks(from: text),
            [
                .paragraph("report:"),
                .code(language: "sh", code: "swift build"),
            ]
        )
    }

    func testEmptyAndWhitespaceOnlyTextYieldNoBlocks() {
        XCTAssertEqual(PostMarkdown.blocks(from: ""), [])
        XCTAssertEqual(PostMarkdown.blocks(from: "\n  \n"), [])
    }

    func testMixedAgentReportShape() {
        let text = """
        ## Why

        The `EngineClient` filter missed archived rooms.

        - decode `cwd`
        - prefer it for archives

        ```swift
        let cwd: String?
        ```
        """
        XCTAssertEqual(
            PostMarkdown.blocks(from: text),
            [
                .heading(level: 2, text: "Why"),
                .paragraph("The `EngineClient` filter missed archived rooms."),
                .listItem(marker: "•", text: "decode `cwd`"),
                .listItem(marker: "•", text: "prefer it for archives"),
                .code(language: "swift", code: "let cwd: String?"),
            ]
        )
    }
}
