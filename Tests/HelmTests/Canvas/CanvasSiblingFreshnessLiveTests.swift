import WebKit
import XCTest

@testable import Helm

/// A **real** `WKWebView` on a **real** `helm-canvas://` origin, serving through the **real**
/// handler: edit a sibling on disk, load again, read what the page got.
///
/// **These were written to prove a fix, and instead disproved the bug — #228 is closed as not
/// reproducible, and this file is what closed it.**
///
/// The ticket said a canvas served a stale sibling from WebKit's on-disk cache, surviving a helm
/// relaunch, and that `./app.js?v=2` was the only way through. A `Cache-Control: no-store` fix
/// was written, reviewed by three agents, and found sound. It was never merged, because with it
/// reverted these measured, three ways:
///
/// - reload in the same webview → fresh bytes
/// - a second webview sharing the persistent `WKWebsiteDataStore` → fresh bytes
/// - two separate processes against a **stable** origin → fresh bytes
///
/// The first attempt at the third one was wrong and is worth recording: `CanvasAddress.host`
/// hashes the artifact's **path**, so a temp directory per run gives every run a different
/// origin and nothing is ever cached for the same host twice. A harness that cannot reach the
/// cache proves nothing about it. Fixed to a stable path — still fresh.
///
/// Then the real thing, which is where the ticket was found: `Helm.app` built from this repo,
/// launched under `HELM_DEFAULTS_SUITE`, a canvas pushed, the sibling edited, **helm quit and
/// relaunched**. Fresh with the fix, fresh without it, and fresh without it for an ES module
/// `import` — the shape #228 actually reported. Six ways, no staleness.
///
/// **So these do not test a fix; there is no fix.** They test the behaviour an operator cares
/// about — *I edited the file, does the page see it?* — which is why they keep their meaning
/// whatever the mechanism turns out to be, and why they would catch a real regression that made
/// a sibling stale. What went wrong in #228 is still unknown; if it recurs, this file is the
/// harness to extend rather than a place to add another header assertion.
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
