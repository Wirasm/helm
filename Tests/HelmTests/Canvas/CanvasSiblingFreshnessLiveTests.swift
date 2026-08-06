import WebKit
import XCTest

@testable import Helm

/// A **real** `WKWebView` on a **real** `helm-canvas://` origin, serving through the **real**
/// handler: edit a sibling on disk, load again, read what the page got.
///
/// **BOTH TESTS HERE PASS WITHOUT THE FIX, AND THAT IS THE MEASUREMENT — not an oversight.**
/// They were written to settle the one claim `CanvasSchemeHandlerTests` cannot make (it asserts
/// the header is on the response, which would pass in a build where WebKit ignored the header
/// entirely), and they failed to settle it in the direction anyone expected. With
/// `Cache-Control` reverted to `origin/development`, measured three ways:
///
/// - reload in the same webview → fresh bytes
/// - a second webview sharing the persistent `WKWebsiteDataStore` → fresh bytes
/// - two separate processes against a **stable** origin → fresh bytes
///
/// So `swift test` cannot reproduce #228. The likeliest reason is that these responses carry
/// no `Last-Modified` and no `Date`, so there is nothing for WebKit's heuristic freshness to
/// work from and the sibling may never have been cacheable here at all; the other candidate is
/// that an unbundled test process has no app container and its `.default()` store does not
/// persist the way `Helm.app`'s does. **Both are untested guesses and neither is in this file
/// as a claim.**
///
/// What that leaves, stated plainly: **#228 was measured against the real app across a real
/// relaunch, and the fix is reasoned rather than measured.** These tests are worth keeping as a
/// *control* — they prove the header does not break serving, that a sibling loads end-to-end
/// through live WebKit, and that a 404 does not stick — and they would catch a future change
/// that made siblings genuinely stale in-process. They are **not** evidence that `no-store` is
/// what fixes the reported bug, and nothing here should be read as saying so.
///
/// The experiment that would settle it needs `Helm.app` itself, quit and relaunched, which is
/// where #228 was found.
///
/// **Why it is safe to keep in the gate**: no display — a `WKWebView` renders offscreen and
/// this never looks at pixels — no network, no TCC grant, no new dependency, `WebKit` is
/// already linked. It is the only live-WebKit test in the suite; if it turns flaky, delete it
/// and keep the measurement in this comment rather than weakening it into another header
/// assertion.
@MainActor
final class CanvasSiblingFreshnessLiveTests: XCTestCase {
    private var directory: URL!
    private var artifact: URL!
    private var sibling: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        artifact = directory.appendingPathComponent("page.html")
        sibling = directory.appendingPathComponent("data.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Edit a sibling, load again in a fresh webview, and the page sees the new bytes.
    ///
    /// **Passes with the fix and without it** — see the type's header for the three ways that
    /// was measured. It is a control: it fails if serving a sibling ever breaks, or if some
    /// future caching scheme makes one genuinely stale in-process.
    func testAnEditedSiblingReachesThePageOnReload() async throws {
        try #"{"version":"v1"}"#.write(to: sibling, atomically: true, encoding: .utf8)
        try Self.pageThatReportsItsSibling.write(to: artifact, atomically: true, encoding: .utf8)

        let page = try Page(artifact: artifact)

        let first = try await page.load()
        XCTAssertEqual(
            first, #"{"version":"v1"}"#,
            "the sibling is served at all — if this fails the rest measures nothing")

        try #"{"version":"v2"}"#.write(to: sibling, atomically: true, encoding: .utf8)

        // A SECOND WEBVIEW, not a reload. #228 was measured across a helm relaunch, and the
        // cache that held the stale bytes lives in the `WKWebsiteDataStore` — shared by every
        // webview and persistent on disk. A reload in the same webview is the weaker case.
        let relaunched = try Page(artifact: artifact)
        let second = try await relaunched.load()
        XCTAssertEqual(
            second, #"{"version":"v2"}"#,
            "an edited sibling must reach the page. `v1` here would be #228 reproduced — WebKit "
                + "serving its cached copy without asking the handler — which is what this "
                + "harness could NOT make happen either way")
    }

    /// A sibling created *after* the page first asked for it.
    ///
    /// The other half of #228, and the reason `refuse()` carries the header too. **Also passes
    /// either way here** — a cached 404 no more reproduced than a cached 200.
    func testASiblingCreatedAfterTheFirstLoadIsFoundOnReload() async throws {
        try Self.pageThatReportsItsSibling.write(to: artifact, atomically: true, encoding: .utf8)

        let page = try Page(artifact: artifact)

        let first = try await page.load()
        XCTAssertEqual(
            first, "MISSING 404", "precondition: the file genuinely is not there yet")

        try #"{"version":"created"}"#.write(to: sibling, atomically: true, encoding: .utf8)

        let second = try await page.reload()
        XCTAssertEqual(
            second, #"{"version":"created"}"#,
            "a 404 cached from before the file existed would keep the page blind to it")
    }

    // MARK: - The page, and the harness that drives it

    /// Reports what it got, whatever it got. A 404 is reported as such rather than thrown,
    /// so the "created afterwards" test can assert on the *first* load meaningfully.
    private static let pageThatReportsItsSibling = """
        <!doctype html><html><body><script>
        fetch('./data.json')
          .then(r => r.ok ? r.text() : Promise.resolve('MISSING ' + r.status))
          .catch(e => 'THREW ' + e)
          .then(t => window.webkit.messageHandlers.probe.postMessage(String(t).trim()));
        </script></body></html>
        """

    /// A real `WKWebView` on a real `helm-canvas://` origin, wired to the real handler.
    @MainActor
    private final class Page: NSObject, WKScriptMessageHandler {
        private let webView: WKWebView
        private let address: URL
        private var pending: CheckedContinuation<String, Never>?

        init(artifact: URL) throws {
            let path = StandardizedPath(artifact.path)
            address = try XCTUnwrap(CanvasAddress.url(for: path))

            let configuration = WKWebViewConfiguration()
            configuration.setURLSchemeHandler(
                CanvasSchemeHandler(
                    artifact: artifact,
                    document: { try? Data(contentsOf: artifact) }),
                forURLScheme: CanvasAddress.scheme)
            webView = WKWebView(
                frame: .init(x: 0, y: 0, width: 320, height: 240),
                configuration: configuration)
            super.init()
            configuration.userContentController.add(self, name: "probe")
        }

        func load() async throws -> String {
            await withCheckedContinuation { continuation in
                pending = continuation
                webView.load(URLRequest(url: address))
            }
        }

        /// **`reload()`, not a second `load()`** — a fresh navigation is the case
        /// `.reloadIgnoringLocalCacheData` already covers for the document, and using it here
        /// would measure that policy instead of the sibling's. Reload is what an operator does.
        func reload() async throws -> String {
            await withCheckedContinuation { continuation in
                pending = continuation
                webView.reload()
            }
        }

        nonisolated func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            let body = message.body as? String ?? ""
            MainActor.assumeIsolated {
                let continuation = pending
                pending = nil
                continuation?.resume(returning: body)
            }
        }
    }
}
