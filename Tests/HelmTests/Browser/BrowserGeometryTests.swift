import XCTest

@testable import Helm

final class BrowserGeometryTests: XCTestCase {
    func testCaretAndPointerRoundTripAcrossLetterboxingAndPillarboxing() throws {
        let page = CGSize(width: 200, height: 100)
        let image = CGSize(width: 400, height: 200)
        let caret = CGRect(x: 40, y: 20, width: 1, height: 18)
        for view in [CGSize(width: 400, height: 300), CGSize(width: 600, height: 200)] {
            let mapped = BrowserGeometry.viewRect(caret, in: view, image: image, page: page)
            for point in [mapped.origin, CGPoint(x: mapped.maxX, y: mapped.maxY)] {
                let back = try XCTUnwrap(
                    BrowserGeometry.pagePoint(point, in: view, image: image, page: page))
                XCTAssertEqual(
                    back.x, point == mapped.origin ? caret.minX : caret.maxX, accuracy: 0.001)
                XCTAssertEqual(
                    back.y, point == mapped.origin ? caret.minY : caret.maxY, accuracy: 0.001)
            }
            XCTAssertNil(BrowserGeometry.pagePoint(.zero, in: view, image: image, page: page))
        }
    }

    func testEmptyGeometryCannotPlaceACaretOrPointer() {
        let size = CGSize(width: 400, height: 200)
        for (view, image, page) in [
            (CGSize.zero, size, size), (size, .zero, size), (size, size, .zero),
        ] {
            XCTAssertEqual(
                BrowserGeometry.viewRect(
                    CGRect(x: 10, y: 10, width: 1, height: 18), in: view, image: image, page: page),
                .zero)
            XCTAssertNil(BrowserGeometry.pagePoint(.zero, in: view, image: image, page: page))
        }
    }
}
