import XCTest

@testable import Helm

/// ⌘+ and ⌘− step through Chrome's own zoom levels (#544).
final class BrowserZoomTests: XCTestCase {
    func testStepsAreChromesLevels() {
        XCTAssertEqual(BrowserZoom.step(from: 1, .increase), 1.1)
        XCTAssertEqual(BrowserZoom.step(from: 1.1, .increase), 1.25)
        XCTAssertEqual(BrowserZoom.step(from: 1, .decrease), 0.9)
        XCTAssertEqual(BrowserZoom.step(from: 2.5, .reset), 1)
    }

    func testTheEndsHold() {
        XCTAssertEqual(BrowserZoom.step(from: 5, .increase), 5)
        XCTAssertEqual(BrowserZoom.step(from: 0.25, .decrease), 0.25)
    }
}
