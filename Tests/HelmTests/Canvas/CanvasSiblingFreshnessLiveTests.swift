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
/// **What went wrong in #228 is no longer unknown, and it was not here.** #261 is the mechanism:
/// helm watched the artifact and nothing beside it, and a re-push of an open canvas refreshed
/// nothing — so `?v=2` worked by editing the `.html`, not by busting a cache. This file measures
/// what WebKit serves and deliberately bypasses `WorkbenchModel`;
/// `CanvasSiblingRefreshTests` is the one that drives a push through it and reads the page.
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
    private var image: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        artifact = directory.appendingPathComponent("page.html")
        sibling = directory.appendingPathComponent("data.json")
        image = directory.appendingPathComponent("probe.svg")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Edit a sibling, load again in a **fresh webview on the same origin**, and the page sees the
    /// new bytes. Not a reload — a second `WKWebView`, because the cache that #228 blamed lives in
    /// the `WKWebsiteDataStore` that every webview shares, and a reload in the same one is the
    /// weaker case. The name says which; an earlier one said "OnReload" and was wrong about its
    /// own body, in a file whose whole value is saying exactly what was measured.
    ///
    /// **Passes with the fix and without it** — see the type's header for the three ways that
    /// was measured. It is a control: it fails if serving a sibling ever breaks, or if some
    /// future caching scheme makes one genuinely stale in-process.
    func testAnEditedSiblingReachesASecondWebViewOnTheSameOrigin() async throws {
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

    // MARK: - An `<img>` sibling (#279)

    /// **The measurement #279 turns on, taken before a line of the fix was written and kept as
    /// the record.** Three facts about one edited `.svg`, in one run, so that no two of them can
    /// be attributed to different states of the machine:
    ///
    /// 1. The `<img>` keeps its old dimensions across the navigation **helm actually performs**
    ///    — `window.__helmTestMark` is gone, so the document is new, and the picture is not.
    /// 2. **Changing the query on `src` clears it, with no navigation at all.**
    /// 3. A `fetch` of the identical URL returns the **new** bytes. So this is not the handler's.
    ///
    /// (2) is the whole basis for helm re-stamping rather than rebuilding the webview: a
    /// re-stamp is a DOM edit, so it reaches a page that took `CanvasUpdate` and was therefore
    /// never navigated. If a query ever stops defeating this cache, this goes red and the fix has
    /// lost its premise — which is why (1) is asserted beside it. A build where (1) starts
    /// reporting `22` has had the bug fixed underneath it, and `restampImagesScript` can go.
    ///
    /// **The order of those three is load-bearing, and getting it wrong said there was no bug.**
    /// The first pass asked (3) first, because it reads as the harmless precondition — and that
    /// `fetch` **refreshes the cache entry for exactly the URL the `<img>` is about to ask for**,
    /// so the navigation then came back fresh and the effect vanished. Two different page shapes
    /// were blamed for that before the real variable turned up: it is not the shape, it is that
    /// something had already re-fetched the URL. So the staleness is measured **first**, on a
    /// page nothing has touched, and the handler's freshness is asked afterwards where it can no
    /// longer flatter the result.
    ///
    /// **The `<img>` is created by script here, and the sibling test below leaves it in the
    /// markup — both go stale.** Scripting it is the markdown canvas's own shape, since
    /// `marked.parse` writes the artifact into `innerHTML`, and having both is what says the
    /// staleness is about the URL rather than about how the element got there.
    ///
    /// **`naturalWidth` is the probe, and it needs no pixels.** An SVG declares its width in
    /// text, so two versions of the sibling are two numbers — read off the element rather than
    /// off the screen, which is what keeps this runnable with no display.
    func testAChangedQueryClearsAnImageThatANavigationDoesNot() async throws {
        try Self.svg(width: 11).write(to: image, atomically: true, encoding: .utf8)
        try Self.pageThatScriptsItsImage.write(to: artifact, atomically: true, encoding: .utf8)

        let page = try Page(artifact: artifact)
        let first = try await page.load()
        XCTAssertEqual(
            first, "11",
            "precondition: the image sibling is served and decoded at all — if this fails the "
                + "rest measures nothing")
        await page.mark()

        try Self.svg(width: 22).write(to: image, atomically: true, encoding: .utf8)

        let afterNavigating = try await page.navigateAgain()
        let marked = await page.stillMarked()
        XCTAssertFalse(
            marked,
            "the navigation has to have actually happened, or (1) below measures nothing — "
                + "`window` does not survive one, so the mark going away IS the new document")
        XCTAssertEqual(
            afterNavigating, "11",
            "(1) #279: the `<img>` keeps its old dimensions across the navigation helm performs. "
                + "WebKit is reusing its decoded copy, keyed by URL")

        let afterStamp = await page.widthAfterPointingImageAt("./probe.svg?helm=2")
        XCTAssertEqual(
            afterStamp, "22",
            "(2) a changed query defeats it, with no navigation — the premise helm re-stamps on. "
                + "`11` here means re-stamping cannot work at all")

        let fetched = await page.siblingText()
        XCTAssertTrue(
            fetched.contains(#"width="22""#),
            "(3) and the handler serves the NEW bytes for the identical URL — so what was stale "
                + "above is neither the handler nor the file. Asked LAST, because asking it "
                + "first is what refreshes the entry (1) exists to catch. Got \(fetched)")
    }

    /// **The same staleness with the `<img>` written in the markup**, which is an `.html`
    /// artifact's ordinary shape and the one the first pass at this measurement mistook for
    /// evidence that the bug did not exist.
    ///
    /// It is here to pin the negative: the difference between the two runs was **the `fetch`**,
    /// not the element. Delete this and the file's only account of #279 is a page that builds
    /// its image with script, which invites exactly the wrong reading — that a re-stamp is a
    /// markdown-canvas workaround rather than a rule about a URL.
    func testAnImageWrittenInTheMarkupGoesStaleTheSameWay() async throws {
        try Self.svg(width: 11).write(to: image, atomically: true, encoding: .utf8)
        try Self.pageThatParsesItsImage.write(to: artifact, atomically: true, encoding: .utf8)

        let page = try Page(artifact: artifact)
        let first = try await page.load()
        XCTAssertEqual(first, "11", "precondition")

        try Self.svg(width: 22).write(to: image, atomically: true, encoding: .utf8)

        let afterNavigating = try await page.navigateAgain()
        XCTAssertEqual(
            afterNavigating, "11",
            "an `<img>` the parser saw goes stale exactly as a scripted one does — nothing here "
                + "turns on how the element was made")

        let afterStamp = await page.widthAfterPointingImageAt("./probe.svg?helm=2")
        XCTAssertEqual(afterStamp, "22", "and the same stamp clears it")
    }

    /// **helm's own script, run verbatim, against the two URLs it must tell apart** — the rule
    /// that a stamp goes on a sibling and never on the page's own bytes.
    ///
    /// A `data:` URI carries the image inside it, so a query appended to one is not a
    /// cache-buster but a broken image. `CanvasHTML.restampImagesScript` refuses it by scheme
    /// and host, and this executes the real string rather than reading it: a substring check on
    /// generated JavaScript is what #197 is the record of.
    ///
    /// It also pins **idempotence** — a second run at the same generation leaves the `src`
    /// exactly as it was, so the two delivery points cannot cost a page two fetches for one
    /// refresh by both firing.
    func testTheRestampScriptStampsASiblingAndLeavesADataURIAlone() async throws {
        try Self.svg(width: 11).write(to: image, atomically: true, encoding: .utf8)
        try Self.pageWithASiblingAndADataURI.write(to: artifact, atomically: true, encoding: .utf8)

        let page = try Page(artifact: artifact)
        _ = try await page.load()

        await page.runInBridgeWorld(CanvasHTML.restampImagesScript(generation: 7))

        let sibling = await page.attribute("src", of: "#sibling")
        XCTAssertTrue(
            sibling.hasSuffix("probe.svg?helm=7"),
            "the sibling is re-pointed at a URL this refresh has not used — got \(sibling)")
        let inline = await page.attribute("src", of: "#inline")
        XCTAssertTrue(
            inline.hasPrefix("data:image/svg+xml"),
            "a `data:` URI is the image, not an address for one — got \(inline)")
        XCTAssertFalse(
            inline.contains("helm=7"),
            "appending a query to it would corrupt the bytes it carries")

        await page.runInBridgeWorld(CanvasHTML.restampImagesScript(generation: 7))
        let again = await page.attribute("src", of: "#sibling")
        XCTAssertEqual(
            again, sibling,
            "running it twice at one generation must change nothing — both delivery points can "
                + "fire for the same refresh, and a second fetch per image is the cost of "
                + "forgetting that")
    }

    // MARK: - The page, and the harness that drives it

    /// **The markdown canvas's shape**: the `<img>` is created by script, exactly as
    /// `marked.parse` creates one when it writes an artifact into `innerHTML`. Reports what the
    /// image decoded to, which is what says *which version of the sibling is on screen* without
    /// looking at a pixel. A throw is reported as such, so a broken probe is told apart from a
    /// stale one.
    private static let pageThatScriptsItsImage = """
        <!doctype html><html><body><div id="content"></div><script>
        document.getElementById('content').innerHTML = '<img src="./probe.svg">';
        var img = document.querySelector('img');
        img.decode()
          .then(function () { return String(img.naturalWidth); })
          .catch(function (e) { return 'THREW ' + e; })
          .then(function (t) { window.webkit.messageHandlers.probe.postMessage(t); });
        </script></body></html>
        """

    /// The same page with the `<img>` in the markup instead — an `.html` artifact's ordinary
    /// shape.
    private static let pageThatParsesItsImage = """
        <!doctype html><html><body><img src="./probe.svg"><script>
        var img = document.querySelector('img');
        img.decode()
          .then(function () { return String(img.naturalWidth); })
          .catch(function (e) { return 'THREW ' + e; })
          .then(function (t) { window.webkit.messageHandlers.probe.postMessage(t); });
        </script></body></html>
        """

    /// One image served over `helm-canvas://`, one carrying its own bytes. The script has to
    /// tell them apart by scheme and host alone — it has no idea what either points at.
    private static let pageWithASiblingAndADataURI = """
        <!doctype html><html><body>
        <img id="sibling" src="./probe.svg">
        <img id="inline" src="data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'\
        %20width='3'%20height='3'%3E%3C/svg%3E">
        <script>window.webkit.messageHandlers.probe.postMessage('up');</script>
        </body></html>
        """

    /// A sibling image whose width says which version of it the page got. SVG rather than a
    /// raster format because it is text, and `naturalWidth` reads the declared width —
    /// `CanvasSiblingRefreshTests` uses the same instrument for the same reason.
    private static func svg(width: Int) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(width)">\
        <rect width="\(width)" height="\(width)" fill="#7cf"/></svg>
        """
    }

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

        /// **What helm's canvases actually do** — `MarkdownCanvasPage.load` and
        /// `HTMLCanvasPage.navigate` both issue exactly this request, and neither calls
        /// `reload()`. The distinction is not pedantry: measured below, `reload()` revalidates
        /// subresources and a fresh navigation to the same URL does not, so a harness that used
        /// `reload()` would report a freshness helm never gets.
        func navigateAgain() async throws -> String {
            await withCheckedContinuation { continuation in
                pending = continuation
                webView.load(URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData))
            }
        }

        /// Leave something on `window` that a navigation destroys, so "did it really reload?"
        /// is a measurement rather than an assumption — `CanvasSiblingRefreshTests` proves the
        /// same thing the same way.
        func mark() async { _ = await ask("window.__helmTestMark = 1; 'ok'") }

        func stillMarked() async -> Bool { await ask("String(!!window.__helmTestMark)") == "true" }

        /// What the page gets when it asks for the image sibling **now** — the real fetch, over
        /// the real handler, from the document currently loaded.
        func siblingText() async -> String {
            await callAsync(
                """
                const r = await fetch('./probe.svg');
                return r.ok ? await r.text() : 'HTTP ' + r.status;
                """)
        }

        /// Point the `<img>` somewhere and report what it decoded to. **No navigation** — this
        /// is a DOM edit on the live document, which is exactly the shape of helm's re-stamp.
        func widthAfterPointingImageAt(_ src: String) async -> String {
            await callAsync(
                """
                const img = document.querySelector('img');
                img.src = \(CanvasHTML.jsString(src));
                await img.decode();
                return String(img.naturalWidth);
                """)
        }

        /// Run something where helm runs it — `CanvasFileCoordinator.bridgeWorld`, whose whole
        /// point is that the page's own JavaScript cannot see it. A DOM edit made from there is
        /// the thing under test, since the two worlds share one document and nothing else.
        func runInBridgeWorld(_ script: String) async {
            await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(
                    script, in: nil, in: CanvasFileCoordinator.bridgeWorld
                ) { _ in continuation.resume() }
            }
        }

        func attribute(_ name: String, of selector: String) async -> String {
            await ask(
                "String((document.querySelector(\(CanvasHTML.jsString(selector))) || {})"
                    + ".getAttribute(\(CanvasHTML.jsString(name))))")
        }

        private func ask(_ script: String) async -> String {
            await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(script) { value, _ in
                    continuation.resume(returning: value as? String ?? "")
                }
            }
        }

        private func callAsync(_ script: String) async -> String {
            await withCheckedContinuation { continuation in
                webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case let .success(value): continuation.resume(returning: value as? String ?? "")
                    case let .failure(error):
                        continuation.resume(returning: "THREW \(error.localizedDescription)")
                    }
                }
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
