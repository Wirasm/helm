import XCTest

@testable import Helm

/// The URL source's allowlist and its address parsing — the whole security story
/// for the second navigation coordinator, and the only part of a webview
/// `swift test` can reach.
final class CanvasURLPolicyTests: XCTestCase {

    // MARK: - Typed addresses

    func testPromotesASchemelessAddressToHTTP() {
        // The dev-server case: nothing else in the app would make this a URL.
        XCTAssertEqual(
            CanvasURLPolicy.address("example.com/docs")?.absoluteString,
            "http://example.com/docs")
    }

    func testReadsHostColonDigitsAsAPortAndNotAsAScheme() {
        // `URL(string:)` alone reads "localhost:3000" as scheme `localhost` with
        // path `3000`. This is the address the whole feature exists for.
        XCTAssertEqual(
            CanvasURLPolicy.address("localhost:3000")?.absoluteString,
            "http://localhost:3000")
        XCTAssertEqual(
            CanvasURLPolicy.address("127.0.0.1:8080/status")?.absoluteString,
            "http://127.0.0.1:8080/status")
    }

    func testKeepsAnExplicitWebScheme() {
        XCTAssertEqual(
            CanvasURLPolicy.address("https://example.com/path?q=1")?.absoluteString,
            "https://example.com/path?q=1")
        XCTAssertEqual(
            CanvasURLPolicy.address("http://example.com:8443/x")?.absoluteString,
            "http://example.com:8443/x")
        XCTAssertNotNil(CanvasURLPolicy.address("HTTPS://example.com"))
    }

    func testTrimsSurroundingWhitespace() {
        // Addresses arrive pasted, and a paste carries the newline with it.
        XCTAssertEqual(
            CanvasURLPolicy.address("  https://example.com \n")?.absoluteString,
            "https://example.com")
    }

    func testRefusesAnExplicitSchemeOutsideTheAllowlistRatherThanRewritingIt() {
        // The rewrite is the trap: prepending http:// to "ssh://host" would turn a
        // refusal into a nonsense request. An explicit scheme is taken at its word.
        for refused in [
            "ssh://root@evil.example",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "x-apple.systempreferences:com.apple.preference",
            "ftp://example.com",
            "mailto:dev@example.com",
        ] {
            XCTAssertNil(CanvasURLPolicy.address(refused), refused)
        }
    }

    func testRefusesFileURLsWhichBelongToTheOtherSource() {
        // The artifact source owns local files and keeps its own coordinator; the
        // address bar must not become a second, unrestricted way in.
        XCTAssertNil(CanvasURLPolicy.address("file:///etc/passwd"))
        XCTAssertNil(CanvasURLPolicy.address("file:///tmp/report.html"))
    }

    func testRefusesAddressesWithNoHost() {
        XCTAssertNil(CanvasURLPolicy.address(""))
        XCTAssertNil(CanvasURLPolicy.address("   \n"))
        XCTAssertNil(CanvasURLPolicy.address("http://"))
        XCTAssertNil(CanvasURLPolicy.address(":3000"))
    }

    // MARK: - Navigations the page starts

    func testAllowsOnlyTheWeb() {
        XCTAssertTrue(CanvasURLPolicy.allows(URL(string: "http://localhost:3000")))
        XCTAssertTrue(CanvasURLPolicy.allows(URL(string: "https://example.com")))
    }

    func testCancelsEverythingElseAPageMightRedirectInto() {
        for refused in [
            "file:///etc/passwd",
            "ssh://root@evil.example",
            "x-apple.systempreferences:com.apple.preference",
            "about:blank",
        ] {
            XCTAssertFalse(CanvasURLPolicy.allows(URL(string: refused)), refused)
        }
        XCTAssertFalse(CanvasURLPolicy.allows(nil))
    }
}
