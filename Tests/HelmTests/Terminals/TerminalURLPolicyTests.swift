import XCTest

@testable import Helm

/// The ⌘-click allowlist. Split out of `TerminalCapabilitiesTests` with the type.
final class TerminalURLPolicyTests: XCTestCase {
    func testAllowsWebMailAndFileSchemes() {
        XCTAssertEqual(
            TerminalURLPolicy.validated("https://example.com/path?q=1")?.absoluteString,
            "https://example.com/path?q=1"
        )
        XCTAssertNotNil(TerminalURLPolicy.validated("http://example.com"))
        XCTAssertNotNil(TerminalURLPolicy.validated("mailto:dev@example.com"))
        XCTAssertNotNil(TerminalURLPolicy.validated("file:///tmp/report.html"))
    }

    func testSchemeMatchingIsCaseInsensitive() {
        XCTAssertNotNil(TerminalURLPolicy.validated("HTTPS://example.com"))
    }

    func testTrimsGridWrappingWhitespace() {
        XCTAssertEqual(
            TerminalURLPolicy.validated("  https://example.com\n")?.absoluteString,
            "https://example.com"
        )
    }

    func testRejectsEveryOtherScheme() {
        // Terminal content is untrusted; NSWorkspace.open would launch
        // whatever app claims these. All must be dropped.
        for hostile in [
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "ssh://root@evil.example",
            "vnc://evil.example",
            "x-apple.systempreferences:com.apple.preference",
            "ftp://example.com",
        ] {
            XCTAssertNil(TerminalURLPolicy.validated(hostile), hostile)
        }
    }

    func testRejectsSchemelessAndEmptyStrings() {
        // No guessing: a bare host is not promoted to https.
        XCTAssertNil(TerminalURLPolicy.validated("example.com/docs"))
        XCTAssertNil(TerminalURLPolicy.validated(""))
        XCTAssertNil(TerminalURLPolicy.validated("   \n"))
    }

    // MARK: - TerminalActivity: progress
}
