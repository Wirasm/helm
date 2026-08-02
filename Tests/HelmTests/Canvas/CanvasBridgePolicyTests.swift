import XCTest

@testable import Helm

/// #33's second constraint: an arbitrary website cannot post into helm.
final class CanvasBridgePolicyTests: XCTestCase {
    func testOnlyAFileSourceCarriesTheBridge() {
        XCTAssertTrue(CanvasBridgePolicy.installsBridge(for: .file(path: "/tmp/plan.md")))
        XCTAssertFalse(
            CanvasBridgePolicy.installsBridge(for: .url(URL(string: "https://example.com")!)),
            "a message handler on a webview that loads arbitrary websites lets any page "
                + "post into helm")
        XCTAssertFalse(CanvasBridgePolicy.installsBridge(for: .empty))
    }

    /// The **structural** half of the guarantee, and the reason the URL source lives in its
    /// own file: it builds its own `WKWebViewConfiguration` and never touches the annotated
    /// one. A policy alone would be one careless line away from being bypassed.
    func testTheURLSourceRegistersNoScriptMessageHandlerAtAll() throws {
        let source = try String(
            contentsOf: Self.sourceRoot.appendingPathComponent("Canvas/URLCanvasViews.swift"),
            encoding: .utf8)

        XCTAssertFalse(
            source.contains("add(") && source.contains("name:"),
            "URLCanvasViews.swift must never register a script message handler")
        XCTAssertFalse(
            source.contains(CanvasBridgePolicy.handlerName),
            "…and must not so much as name the bridge")
    }

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Canvas/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // the repo root
            .appendingPathComponent("Sources/Helm")
    }
}
