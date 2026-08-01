import XCTest

@testable import Helm

/// File-kind routing, moved here with the type itself — these cases previously
/// lived in `ArtifactHTMLTests` when routing sat on the HTML generator.
final class RenderableFileTests: XCTestCase {
    func testMarkdownExtensionsDetected() {
        XCTAssertTrue(RenderableFile.isMarkdown(URL(fileURLWithPath: "/a/plan.md")))
        XCTAssertTrue(RenderableFile.isMarkdown(URL(fileURLWithPath: "/a/PLAN.MD")))
        XCTAssertTrue(RenderableFile.isMarkdown(URL(fileURLWithPath: "/a/notes.markdown")))
        XCTAssertFalse(RenderableFile.isMarkdown(URL(fileURLWithPath: "/a/build.log")))
        XCTAssertFalse(RenderableFile.isMarkdown(URL(fileURLWithPath: "/a/script.sh")))
    }

    func testHTMLExtensionsDetected() {
        XCTAssertTrue(RenderableFile.isHTML(URL(fileURLWithPath: "/a/page.html")))
        XCTAssertTrue(RenderableFile.isHTML(URL(fileURLWithPath: "/a/PAGE.HTM")))
        XCTAssertFalse(RenderableFile.isHTML(URL(fileURLWithPath: "/a/plan.md")))
    }

    /// The question the terminal and the browser actually ask: is there a renderer
    /// at all. A ⌘-clicked link to anything else must still reach the system.
    func testRenderableIsMarkdownOrHTMLOnly() {
        XCTAssertTrue(RenderableFile.isRenderable(URL(fileURLWithPath: "/a/plan.md")))
        XCTAssertTrue(RenderableFile.isRenderable(URL(fileURLWithPath: "/a/canvas.html")))
        XCTAssertFalse(RenderableFile.isRenderable(URL(fileURLWithPath: "/a/diagram.png")))
        XCTAssertFalse(RenderableFile.isRenderable(URL(fileURLWithPath: "/a/Main.swift")))
        XCTAssertFalse(RenderableFile.isRenderable(URL(fileURLWithPath: "/a/notes")))
    }
}
