import XCTest

@testable import Helm

/// A canvas had no name an agent could mean, and no way to tell which canvas a bridge
/// message came from. These are the two halves of the answer: the host that names one
/// artifact, and the rule for whether a message really came from it.
final class CanvasAddressTests: XCTestCase {

    // MARK: - The host names one artifact

    func testTheSameArtifactAlwaysGetsTheSameHost() {
        XCTAssertEqual(
            CanvasAddress.host(for: StandardizedPath("/tmp/plan.md")),
            CanvasAddress.host(for: StandardizedPath("/tmp/plan.md")),
            "the host has to survive a reload and a relaunch, or an agent's address for a "
                + "canvas stops meaning that canvas")
    }

    func testDifferentArtifactsGetDifferentHosts() {
        XCTAssertNotEqual(
            CanvasAddress.host(for: StandardizedPath("/tmp/plan.md")),
            CanvasAddress.host(for: StandardizedPath("/tmp/tasks.md")))
    }

    func testTwoSpellingsOfOneFileAreOneHost() {
        // This is #88 and #108 meeting: the workbench decides "already open?" by comparing
        // sources, and the bridge decides "which canvas?" by comparing hosts. If those two
        // disagreed, one file could be one pane with two origins.
        XCTAssertEqual(
            CanvasAddress.host(for: StandardizedPath("/tmp/./plan.md")),
            CanvasAddress.host(for: StandardizedPath("/tmp/plan.md")))
    }

    func testTheHostIsALegalHost() {
        // A path may hold spaces, slashes, `~` and non-ASCII; a host may hold none of them.
        let host = CanvasAddress.host(for: StandardizedPath("/tmp/a plan (v2)/rapport – å.md"))

        XCTAssertFalse(host.isEmpty)
        XCTAssertEqual(
            host, host.lowercased(),
            "host comparison is case-insensitive; emitting lowercase "
                + "means that can never surprise anyone")
        XCTAssertTrue(
            host.allSatisfy { $0.isHexDigit }, "hex is always a legal host — got \(host)")
    }

    func testTheURLCarriesTheSchemeTheHostAndTheArtifactName() throws {
        let path = StandardizedPath("/tmp/plans/plan.md")
        let url = try XCTUnwrap(CanvasAddress.url(for: path))

        XCTAssertEqual(url.scheme, CanvasAddress.scheme)
        XCTAssertEqual(url.host, CanvasAddress.host(for: path))
        XCTAssertEqual(
            url.path, "/plan.md",
            "the artifact keeps its own name so a page's relative references resolve to "
                + "siblings on the same host")
    }

    // MARK: - Which messages are this canvas's

    func testAMessageFromTheExpectedOriginIsAccepted() {
        let host = CanvasAddress.host(for: StandardizedPath("/tmp/plan.md"))

        XCTAssertTrue(
            CanvasAddress.accepts(
                isMainFrame: true, originScheme: CanvasAddress.scheme, originHost: host,
                expectedHost: host))
    }

    func testAMessageFromAnotherCanvasIsRefused() {
        XCTAssertFalse(
            CanvasAddress.accepts(
                isMainFrame: true,
                originScheme: CanvasAddress.scheme,
                originHost: CanvasAddress.host(for: StandardizedPath("/tmp/other.md")),
                expectedHost: CanvasAddress.host(for: StandardizedPath("/tmp/plan.md"))),
            "this is the whole point of the slice — a canvas may only speak for itself")
    }

    func testASubframeIsRefusedEvenOnTheRightHost() {
        // `forMainFrameOnly: true` scopes helm's injected SCRIPT, not the HANDLER — a
        // cross-origin iframe does reach the handler, confirmed empirically. So the frame
        // has to be checked here rather than assumed.
        let host = CanvasAddress.host(for: StandardizedPath("/tmp/plan.md"))

        XCTAssertFalse(
            CanvasAddress.accepts(
                isMainFrame: false, originScheme: CanvasAddress.scheme, originHost: host,
                expectedHost: host))
    }

    func testAnotherSchemeOnTheRightHostIsRefused() {
        let host = CanvasAddress.host(for: StandardizedPath("/tmp/plan.md"))

        XCTAssertFalse(
            CanvasAddress.accepts(
                isMainFrame: true, originScheme: "https", originHost: host, expectedHost: host))
        XCTAssertFalse(
            CanvasAddress.accepts(
                isMainFrame: true, originScheme: "file", originHost: host, expectedHost: host))
    }

    func testAnOriginlessMessageIsRefused() {
        // What a `loadHTMLString(baseURL: nil)` page looked like before this slice: no
        // origin at all. It must fail closed rather than match an empty expectation.
        let host = CanvasAddress.host(for: StandardizedPath("/tmp/plan.md"))

        XCTAssertFalse(
            CanvasAddress.accepts(
                isMainFrame: true, originScheme: nil, originHost: nil, expectedHost: host))
        XCTAssertFalse(
            CanvasAddress.accepts(
                isMainFrame: true, originScheme: CanvasAddress.scheme, originHost: "",
                expectedHost: ""),
            "an unaddressable canvas must accept nothing, not everything")
    }
}
