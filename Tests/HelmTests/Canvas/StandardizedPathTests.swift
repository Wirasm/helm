import XCTest

@testable import Helm

/// `Workbench.pane(showing:)` decides "is this file already open?" by comparing sources by
/// value, so the guarantee that makes ⌘-clicking one link twice open one canvas is that
/// every path was standardized on the way in. #88: that used to be a doc comment asking
/// callers to be careful, and `WorkbenchTests`' own helper already wasn't.
final class StandardizedPathTests: XCTestCase {

    func testEveryRouteInStandardizes() {
        let expected = "/tmp/plan.md"

        XCTAssertEqual(StandardizedPath("/tmp/./plan.md").value, expected)
        XCTAssertEqual(StandardizedPath("/tmp/sub/../plan.md").value, expected)
        XCTAssertEqual(StandardizedPath(URL(fileURLWithPath: "/tmp/./plan.md")).value, expected)
        XCTAssertEqual(StandardizedPath("/tmp//plan.md").value, expected)
    }

    func testTwoSpellingsOfOneFileAreEqual() {
        XCTAssertEqual(StandardizedPath("/tmp/./plan.md"), StandardizedPath("/tmp/plan.md"))
    }

    func testDecodingStandardizesToo() throws {
        // A hand-edited defaults blob is a route in like any other. This is what stops a
        // restore turning one canvas into two.
        let raw = Data(#""/tmp/./plan.md""#.utf8)
        let decoded = try JSONDecoder().decode(StandardizedPath.self, from: raw)

        XCTAssertEqual(decoded.value, "/tmp/plan.md")
    }

    func testItRoundTripsAsAPlainString() throws {
        let encoded = try JSONEncoder().encode(StandardizedPath("/tmp/plan.md"))

        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self), #""\/tmp\/plan.md""#,
            "a pane's source is something an operator may have to read in `defaults read`, "
                + "so the path stays a plain string rather than gaining a wrapper object")
        XCTAssertEqual(
            try JSONDecoder().decode(StandardizedPath.self, from: encoded),
            StandardizedPath("/tmp/plan.md"))
    }

    func testACanvasSourceBuiltEitherWayIsTheSameSource() {
        XCTAssertEqual(
            CanvasSource.file(URL(fileURLWithPath: "/tmp/./plan.md")),
            CanvasSource.file("/tmp/plan.md"))
    }

    func testTheFileURLComesBackFromTheWrappedValue() {
        XCTAssertEqual(
            CanvasSource.file("/tmp/./plan.md").fileURL,
            URL(fileURLWithPath: "/tmp/plan.md"))
    }
}
