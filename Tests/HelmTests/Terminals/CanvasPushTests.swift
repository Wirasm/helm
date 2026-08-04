import XCTest

@testable import Helm

/// The classification an agent's `printf` lands on. A ghostty callback cannot be built in a
/// test, which is exactly why this decision is a pure function and not a branch inside the
/// delegate.
final class CanvasPushTests: XCTestCase {

    // MARK: - Ordinary notifications are still notifications

    func testAnOrdinaryNotificationIsNotAPush() {
        XCTAssertEqual(
            CanvasPush.classify(title: "Build finished", body: "42 tests passed"), .notAPush)
        XCTAssertEqual(CanvasPush.classify(title: "", body: ""), .notAPush)
    }

    func testAMarkerLookalikeIsNotAPush() {
        // The cost of a collision is a banner silently becoming a pane, so the match is
        // exact rather than a prefix or a contains.
        for near in ["helm", "helm.canvases", "helm.canvas.open", "Helm.Canvas", "x helm.canvas"] {
            XCTAssertEqual(
                CanvasPush.classify(title: near, body: "/tmp/plan.md"), .notAPush,
                "\"\(near)\" must not be taken for the marker")
        }
    }

    func testSurroundingWhitespaceInTheMarkerIsTolerated() {
        // A shell heredoc or a printf with a stray space should not silently become a
        // notification the operator never sees the point of.
        XCTAssertEqual(
            CanvasPush.classify(title: " helm.canvas ", body: "/tmp/plan.md"),
            .open(URL(fileURLWithPath: "/tmp/plan.md")))
    }

    // MARK: - What a push opens

    func testAnAbsolutePathToARenderableFileOpens() {
        XCTAssertEqual(
            CanvasPush.classify(title: CanvasPush.marker, body: "/tmp/plan.md"),
            .open(URL(fileURLWithPath: "/tmp/plan.md")))
        XCTAssertEqual(
            CanvasPush.classify(title: CanvasPush.marker, body: "/tmp/report.html"),
            .open(URL(fileURLWithPath: "/tmp/report.html")))
    }

    func testAFileURLOpens() {
        XCTAssertEqual(
            CanvasPush.classify(title: CanvasPush.marker, body: "file:///tmp/plan.md"),
            .open(URL(fileURLWithPath: "/tmp/plan.md")))
    }

    func testThePathIsStandardized() {
        // So a push and a ⌘-click on the same file reach one pane rather than two —
        // `Workbench.pane(showing:)` compares sources by value (#88).
        XCTAssertEqual(
            CanvasPush.classify(title: CanvasPush.marker, body: "/tmp/./plan.md"),
            .open(URL(fileURLWithPath: "/tmp/plan.md")))
    }

    func testTrailingNewlineFromPrintfIsTolerated() {
        // `printf '…%s\n'` is the shape an agent will actually write.
        XCTAssertEqual(
            CanvasPush.classify(title: CanvasPush.marker, body: "/tmp/plan.md\n"),
            .open(URL(fileURLWithPath: "/tmp/plan.md")))
    }

    // MARK: - What it refuses, and says so

    private func refusal(_ body: String) -> String? {
        if case let .refused(why) = CanvasPush.classify(title: CanvasPush.marker, body: body) {
            return why
        }
        return nil
    }

    func testAFileHelmCannotRenderIsRefusedWithAReason() throws {
        let why = try XCTUnwrap(refusal("/tmp/archive.zip"))
        XCTAssertTrue(
            why.contains("archive.zip"),
            "the refusal has to name the file, or the agent cannot act on it — got: \(why)")
    }

    func testARelativePathIsRefusedRatherThanResolved() throws {
        // The only cwd helm could resolve against is the pane's, which need not be the cwd
        // of the process that printed the sequence. Opening the wrong file is worse than
        // refusing.
        XCTAssertNotNil(refusal("plan.md"))
        XCTAssertNotNil(refusal("./plan.md"))
        XCTAssertNotNil(refusal("~/plan.md"))
    }

    func testAnEmptyBodyIsRefused() throws {
        XCTAssertNotNil(refusal(""))
        XCTAssertNotNil(refusal("   "))
    }

    func testANonFileURLIsRefused() throws {
        XCTAssertNotNil(refusal("https://example.com/plan.md"))
    }

    func testEveryRefusalSaysSomething() {
        for body in ["/tmp/archive.zip", "plan.md", "", "https://example.com/x.md"] {
            guard case let .refused(why) = CanvasPush.classify(title: CanvasPush.marker, body: body)
            else {
                XCTFail("\"\(body)\" should have been refused")
                continue
            }
            XCTAssertFalse(
                why.isEmpty,
                "a silent refusal is indistinguishable from a channel that does not work")
        }
    }
}
