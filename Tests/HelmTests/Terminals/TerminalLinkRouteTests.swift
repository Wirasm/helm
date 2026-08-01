import XCTest

@testable import Helm

/// Where a ⌘-clicked OSC 8 link ends up. The file half is covered by
/// `RenderableFileTests`; this covers the routing decision built on it — including
/// the one the canvas exists for, an agent-printed http address opening in helm
/// rather than in a browser.
final class TerminalLinkRouteTests: XCTestCase {

    // MARK: - Web addresses go to the canvas

    func testWebAddressesOpenInTheCanvas() {
        // The case the canvas exists for: an agent prints its dev server.
        let localhost = URL(string: "http://localhost:3000")!
        XCTAssertEqual(TerminalLinkRoute.route(localhost), .canvasURL(localhost))

        let https = URL(string: "https://example.com/path?q=1")!
        XCTAssertEqual(TerminalLinkRoute.route(https), .canvasURL(https))

        let port = URL(string: "http://127.0.0.1:8080/status")!
        XCTAssertEqual(TerminalLinkRoute.route(port), .canvasURL(port))
    }

    func testSchemeMatchingIsCaseInsensitive() {
        let shouty = URL(string: "HTTPS://example.com")!
        XCTAssertEqual(TerminalLinkRoute.route(shouty), .canvasURL(shouty))
    }

    // MARK: - mailto: stays with the system

    func testMailtoGoesToTheSystem() {
        // helm has no mail client and should not pretend to. It passes the outer
        // allowlist and the canvas refuses it — that is the composition working,
        // not a gap in it.
        let mail = URL(string: "mailto:dev@example.com")!
        XCTAssertEqual(TerminalLinkRoute.route(mail), .system(mail))
    }

    // MARK: - Files: unchanged by this route

    func testRenderableFilesOpenInTheCanvas() {
        for path in ["/tmp/plan.md", "/tmp/report.html", "/tmp/page.HTM"] {
            let url = URL(fileURLWithPath: path)
            XCTAssertEqual(TerminalLinkRoute.route(url), .canvasFile(url), path)
        }
    }

    func testUnrenderableFilesGoToTheSystem() {
        // A PDF, an image, an extensionless file: the system owns the apps for these.
        for path in ["/tmp/diagram.png", "/tmp/spec.pdf", "/tmp/Main.swift", "/tmp/notes"] {
            let url = URL(fileURLWithPath: path)
            XCTAssertEqual(TerminalLinkRoute.route(url), .system(url), path)
        }
    }

    // MARK: - Composed with the outer gate

    func testHostileSchemesNeverReachTheCanvas() {
        // Terminal content is untrusted. `TerminalURLPolicy` drops these before the
        // route is ever asked, so neither canvas branch can be reached with one.
        for hostile in [
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "ssh://root@evil.example",
            "x-apple.systempreferences:com.apple.preference",
            "ftp://example.com",
        ] {
            XCTAssertNil(TerminalURLPolicy.validated(hostile), hostile)
        }
    }

    func testGateAndRouteAgreeOnWhatAClickDoes() {
        // The whole decision, from the string ghostty hands over to where it lands.
        let expected: [(String, TerminalLinkRoute?)] = [
            ("http://localhost:3000", .canvasURL(URL(string: "http://localhost:3000")!)),
            ("  https://example.com\n", .canvasURL(URL(string: "https://example.com")!)),
            ("mailto:dev@example.com", .system(URL(string: "mailto:dev@example.com")!)),
            ("file:///tmp/plan.md", .canvasFile(URL(string: "file:///tmp/plan.md")!)),
            ("file:///tmp/diagram.png", .system(URL(string: "file:///tmp/diagram.png")!)),
            // Dropped by the gate: no route, no click.
            ("ssh://root@evil.example", nil),
            ("example.com/docs", nil),
        ]

        for (raw, route) in expected {
            let clicked = TerminalURLPolicy.validated(raw).map(TerminalLinkRoute.route)
            XCTAssertEqual(clicked, route, raw)
        }
    }
}
