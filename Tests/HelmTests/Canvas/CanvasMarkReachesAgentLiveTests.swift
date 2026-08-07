import Combine
import HelmWire
import WebKit
import XCTest

@testable import Helm

/// The same journey as `CanvasMarkReachesAgentTests`, in a **real `WKWebView`** — real
/// `helm-canvas://` origin, real `CanvasSchemeHandler`, real `CanvasFileCoordinator`, the real
/// annotation script injected by WebKit at `.atDocumentEnd` into the real named content world,
/// real WebKit layout and a real `document.getSelection()`. Out the far end: `CanvasModel`,
/// `CanvasAnnotation.decode`, the sidecar, and a message in a mailbox on disk.
///
/// **What this reaches that JavaScriptCore cannot**, which is the whole reason it exists —
/// `CanvasScriptRuntime`'s own header names these three as out of its reach:
///
/// - **The content world.** `installBridge` registers the handler `contentWorld:` and injects the
///   script `in:` `CanvasFileCoordinator.bridgeWorld`. #190 was a world mismatch — the toolbar
///   highlighted and nothing else happened — and every substring assertion passed through it.
///   Here the mark only arrives if both halves landed in the same world, by WebKit's doing.
/// - **Injection time.** `.atDocumentEnd`, `forMainFrameOnly: true`.
/// - **Geometry from a layout engine.** `canvas-dom-stub.js` says in as many words that its boxes
///   are the stub's arithmetic and not a browser's. Here `getBoundingClientRect()` is WebKit's:
///   the page reports its own rects and the loop is drawn from those, never from a constant.
///
/// **It also crosses the origin gate for real.** `CanvasFileCoordinator.userContentController`
/// checks `CanvasAddress.accepts(isMainFrame:originScheme:originHost:expectedHost:)` against a
/// `WKFrameInfo` this test does not construct and could not fake.
///
/// # Two measurements this harness is built on, because both were surprises
///
/// **1. `evaluateJavaScript` runs, but its result never comes back in this test host.** Every
/// overload — including `async` — resumes immediately with `()` for expressions that plainly
/// return a string, on a page that has demonstrably finished loading. The script itself *does*
/// execute: measured by having a bridge-world evaluate set a DOM attribute and letting the page's
/// own script report it back, which returned the real rect width and
/// `typeof window.__helmWipeMark === "function"`. So this harness **issues** JavaScript and never
/// **reads** it: everything it needs to know comes back either through the real bridge (into
/// `CanvasModel`) or through the page's own `postMessage`.
///
/// **2. Polling with `Task.sleep` while awaiting `evaluateJavaScript` stops the load dead** —
/// `webView.isLoading` was false and no document existed after 4s. Waiting on a real callback
/// instead loads in ~150ms. So nothing here sleeps: the load is awaited on the page's own message,
/// and the mark on `model.$selection`. That is the same discipline `helm-spawn` is built on —
/// wait on something observable, never on a duration.
///
/// **Why it is safe in the gate**: no display — a `WKWebView` renders offscreen and nothing here
/// looks at pixels — no network, no TCC grant, no new dependency (`WebKit` is already linked, and
/// `CanvasSiblingFreshnessLiveTests` established the shape). If it ever turns flaky, delete it and
/// keep `CanvasMarkReachesAgentTests`, which measures the same path one layer down.
///
/// **What it still cannot claim**: the gesture is a real `MouseEvent` dispatched on the real
/// document, not a hand on a trackpad. WebKit's own hit-testing of a physical drag needs a window
/// and an event tap; that stays a manual check.
@MainActor
final class CanvasMarkReachesAgentLiveTests: XCTestCase {
    private var mailRoot: URL!
    private var artifacts: URL!
    private var canvas: URL!

    private let handle = Handle(validating: "sild-611a")!
    private let agentPid: pid_t = 40501

    /// An agent-authored artifact: every anchor in it is an id its author can grep for, which is
    /// the asymmetry #33 rests the whole anchor design on. Its script reports each section's real
    /// rect once the page is up — the only way a result crosses back, per measurement 1 above.
    private static let artifactHTML = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 0; font: 16px/1.4 system-ui; }
        section { display: block; padding: 24px; }
        </style></head><body>
        <section id="summary">The bridge payload has no kind discriminator.</section>
        <section id="bridge">This shouldn't talk to that.</section>
        <section id="closing">Filed as an observation, not a work item.</section>
        <script>
        window.webkit.messageHandlers.helmLiveProbe.postMessage(JSON.stringify(
          Array.prototype.map.call(document.querySelectorAll('section'), function (el) {
            var r = el.getBoundingClientRect();
            return { id: el.id, x: r.left, y: r.top, width: r.width, height: r.height };
          })));
        // **The text mark, reported from the PAGE world** (#308). `CSS.highlights` is the
        // document's one registry, and this side of it is the side the renderer reads — so a
        // highlight helm registered from its isolated bridge world being visible HERE is the
        // whole claim, and it is a claim nothing but a real WebKit can settle. Asked by the
        // bridge world setting an attribute, because a bridge-world `evaluateJavaScript`
        // result never comes back in this test host (measurement 1 above).
        setInterval(function () {
          if (document.body.getAttribute('data-helm-ask') === null) { return; }
          document.body.removeAttribute('data-helm-ask');
          var held = window.CSS && CSS.highlights ? CSS.highlights.get('helm-mark') : null;
          var range = held ? Array.from(held)[0] : null;
          window.webkit.messageHandlers.helmLiveProbe.postMessage(JSON.stringify({
            painted: !!held,
            collapsed: range ? range.collapsed : null,
            covers: range ? String(range) : null,
            rule: Array.prototype.some.call(document.adoptedStyleSheets || [], function (s) {
              return Array.prototype.some.call(s.cssRules, function (r) {
                return r.cssText.indexOf('highlight(helm-mark)') >= 0;
              });
            })
          }));
        }, 10);
        </script>
        </body></html>
        """

    override func setUpWithError() throws {
        let fm = FileManager.default
        let mail = fm.temporaryDirectory.appendingPathComponent("helm-live-mail-\(UUID())")
        let artifactDir = fm.temporaryDirectory.appendingPathComponent("helm-live-canvas-\(UUID())")
        try fm.createDirectory(
            at: mail.appendingPathComponent("sild-611a"), withIntermediateDirectories: true)
        try """
        {"handle":"sild-611a","runtime":"claude","pid":40501,
         "sessionId":"e6f1c2d8-0000-4000-8000-0000000611a4","cwd":"/work",
         "claimedAt":1785831967319}
        """
        .write(
            to: mail.appendingPathComponent("sild-611a/owner.json"),
            atomically: true, encoding: .utf8)
        try fm.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let artifact = artifactDir.appendingPathComponent("report.html")
        try Self.artifactHTML.write(to: artifact, atomically: true, encoding: .utf8)

        mailRoot = mail
        artifacts = artifactDir
        canvas = artifact
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: mailRoot)
        try? FileManager.default.removeItem(at: artifacts)
    }

    // MARK: - The tests

    /// A text selection the operator made on a live page, marked and commented, arriving in the
    /// mailbox of the agent that pushed the canvas — anchor and all.
    func testAHighlightOnALivePageReachesTheAgentsMailbox() async throws {
        let page = try await Page(canvas: canvas, mailRoot: mailRoot, route: .mailbox(handle))

        try await page.markSelection(of: "bridge")
        page.model.annotate(comment: "this is the seam #210 is about")

        let message = try delivered()
        XCTAssertEqual(message["to"] as? String, handle.value)
        XCTAssertEqual(message["from"] as? String, CanvasNoteCourier.sender)
        XCTAssertEqual(message["subject"] as? String, "canvas note on report.html")
        let body = try XCTUnwrap(message["body"] as? String)
        XCTAssertTrue(body.contains("`#bridge`"), "the anchor the agent can grep for — \(body)")
        XCTAssertTrue(body.contains("This shouldn't talk to that"), "…and what it covered")
        XCTAssertTrue(body.contains("this is the seam #210 is about"))
        XCTAssertEqual(
            page.model.notesNotice, "Written to report.notes.md and sent to sild-611a")
    }

    /// **A circle drawn round a real element, over WebKit's real layout.** The stroke is computed
    /// from the rect the page itself reported, so what the mark covers is decided by
    /// `getBoundingClientRect()` and the script's own containment rule rather than by a stub's
    /// arithmetic — the gap #196 lived in.
    ///
    /// It is also the geometry mark `CanvasPageSelection.init?` dropped for months (#216),
    /// carrying `targets` and no top-level `text`, now crossing a live bridge rather than a
    /// hand-built dictionary.
    func testACircleDrawnRoundALiveElementReachesTheMailboxNamingWhatItCovered() async throws {
        let page = try await Page(canvas: canvas, mailRoot: mailRoot, route: .mailbox(handle))

        try await page.markLoop(around: "bridge")
        page.model.annotate(comment: "circle exactly this one")

        let body = try XCTUnwrap(try delivered()["body"] as? String)
        XCTAssertTrue(body.contains("circled"), "the gesture is the verb — \(body)")
        XCTAssertTrue(body.contains("`#bridge`"), "what the loop covered, by real layout")
        XCTAssertFalse(
            body.contains("`#summary`") || body.contains("`#closing`"),
            "a loop round one section must not sweep in its neighbours — \(body)")
    }

    /// **The text mark, painted by a real WebKit and read back from the page's own world**
    /// (#308). This is the measurement the whole approach rests on and the one nothing else in
    /// the suite can make: `CanvasScriptRuntime` runs against a DOM stub whose highlight
    /// registry is a dictionary this repo wrote, so it can say the script *called* the API and
    /// never that WebKit has one. Three things are only true here —
    ///
    /// - `CSS.highlights` and `Highlight` exist in the **bridge content world** at all;
    /// - a highlight registered there is visible in the **page** world, so it is the document's
    ///   registry the renderer reads rather than a per-world copy — which is the entire reason
    ///   this could be built without touching the artifact's DOM;
    /// - a `CSSStyleSheet` constructed and adopted from the bridge world parses its
    ///   `::highlight()` rule, so there is something to paint the range *with*.
    ///
    /// And the behaviour the operator asked for, against the real thing that used to take it
    /// away: **the native selection is dropped** — `removeAllRanges()`, which is what the
    /// comment field taking the keyboard amounts to — and helm's mark is still there, still
    /// covering the same words. That is the assertion `cloneRange()` exists for.
    ///
    /// It stops at "registered, uncollapsed, with a rule to paint it". Whether the tint *looks*
    /// right is the operator's call and no test's: a `WKWebView` here renders offscreen and
    /// nothing in this file looks at a pixel.
    func testALiveTextMarkStaysPaintedAfterTheSelectionItCameFromIsGone() async throws {
        let page = try await Page(canvas: canvas, mailRoot: mailRoot, route: .mailbox(handle))

        try await page.markSelection(of: "bridge")

        let painted = try await page.reportHighlight(afterDroppingTheNativeSelection: true)
        XCTAssertEqual(painted["painted"] as? Bool, true, "the page world must see helm's mark")
        XCTAssertEqual(
            painted["collapsed"] as? Bool, false,
            "a range the Selection collapsed under helm is a mark that is no longer over anything")
        XCTAssertEqual(
            painted["covers"] as? String, "This shouldn't talk to that.",
            "and it still covers the passage the comment is about")
        XCTAssertEqual(
            painted["rule"] as? Bool, true,
            "a registered highlight with no ::highlight() rule adopted paints nothing at all")

        // Posted, or dismissed by the ✕ or Escape — one path out, and it is the one that
        // already took the ink down.
        page.clearMark()
        let gone = try await page.highlightGoes()
        XCTAssertTrue(gone, "closing the field takes the text mark with it")
    }

    /// The negative half on a live page: no origin, no mail, and the pane says so.
    ///
    /// **This one passes with the routing removed as well** — it asserts an absence — so it is a
    /// control against overshoot, not evidence for the feature. Named as one, per `AGENTS.md`.
    func testALivePageWithNoOriginSendsNothingAndSaysSo() async throws {
        let page = try await Page(canvas: canvas, mailRoot: mailRoot, route: .clipboard(.noOrigin))

        try await page.markSelection(of: "summary")
        page.model.annotate(comment: "nobody pushed this")

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: mailRoot.appendingPathComponent(handle.value).path),
            ["owner.json"], "an unrouted note must not write into a mailbox at all")
        XCTAssertEqual(
            page.model.notesNotice,
            "Written to report.notes.md and copied — no agent pushed this canvas, "
                + "so paste it to one")
    }

    // MARK: -

    private func delivered() throws -> [String: Any] {
        let box = mailRoot.appendingPathComponent(handle.value)
        let names = try FileManager.default.contentsOfDirectory(atPath: box.path)
            .filter { $0.hasSuffix(".json") && $0 != "owner.json" && !$0.hasPrefix(".") }
        XCTAssertEqual(names.count, 1, "exactly one message, named \(names)")
        let data = try Data(contentsOf: box.appendingPathComponent(try XCTUnwrap(names.first)))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The harness

    /// The page's own channel back to the test — **not** helm's bridge, and deliberately in the
    /// **page** content world. It is how the artifact reports its real layout, and it doubles as
    /// proof that the two worlds are separate: this handler is the only thing the page's own
    /// script can reach, and `helmCanvas` is not visible to it at all.
    @MainActor
    private final class PageProbe: NSObject, WKScriptMessageHandler {
        static let name = "helmLiveProbe"
        var pending: CheckedContinuation<String, Never>?

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

    /// A live canvas pane, minus the pane: the same `WKWebViewConfiguration`
    /// `HTMLCanvasWebView.makeNSView` builds, wired to a real `CanvasModel` whose `onAnnotation`
    /// is a real `CanvasNoteCourier` on a mailbox this test owns.
    @MainActor
    private final class Page {
        let model: CanvasModel
        private let webView: WKWebView
        private let coordinator: CanvasFileCoordinator
        private let probe = PageProbe()
        private var rects: [String: CGRect] = [:]
        private var marks: AnyCancellable?

        init(canvas: URL, mailRoot: URL, route: CanvasNoteRoute) async throws {
            let path = StandardizedPath(canvas)
            let model = CanvasModel(source: .file(canvas))
            self.model = model
            let courier = CanvasNoteCourier(mailboxRoot: mailRoot)
            model.onAnnotation = { annotation, canvas in
                courier.send(annotation, on: canvas, along: route)
            }
            // The clipboard this suite is allowed to write to. A `.clipboard` route copies, and
            // the default sink is the operator's own `NSPasteboard.general` — see
            // `CanvasModel.copyToClipboard`. Discarded rather than captured because what this file
            // measures is a live WebKit page, and `CanvasMarkReachesAgentTests` is where the copy
            // itself is asserted.
            model.copyToClipboard = { _ in }

            coordinator = CanvasFileCoordinator(
                host: CanvasAddress.host(for: path), onAnnotation: model.pageDidReport)

            let configuration = WKWebViewConfiguration()
            let artifact = URL(fileURLWithPath: path.value)
            configuration.setURLSchemeHandler(
                CanvasSchemeHandler(artifact: artifact) { try? Data(contentsOf: artifact) },
                forURLScheme: CanvasAddress.scheme)
            coordinator.installBridge(on: configuration.userContentController)
            configuration.userContentController.add(probe, name: PageProbe.name)
            webView = WKWebView(
                frame: .init(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
            webView.navigationDelegate = coordinator

            let address = try XCTUnwrap(CanvasAddress.url(for: path))
            let reported = await withCheckedContinuation {
                (continuation: CheckedContinuation<String, Never>) in
                probe.pending = continuation
                webView.load(URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData))
            }
            rects = try Self.decodeRects(reported)
        }

        private static func decodeRects(_ json: String) throws -> [String: CGRect] {
            let rows = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
                "the live page reported no layout: \(json)")
            var boxes: [String: CGRect] = [:]
            for row in rows {
                guard let id = row["id"] as? String else { continue }
                func number(_ key: String) -> CGFloat {
                    CGFloat((row[key] as? NSNumber)?.doubleValue ?? 0)
                }
                boxes[id] = CGRect(
                    x: number("x"), y: number("y"), width: number("width"),
                    height: number("height"))
            }
            XCTAssertFalse(boxes.isEmpty, "the artifact never rendered")
            for (id, rect) in boxes {
                XCTAssertFalse(rect.isEmpty, "#\(id) has no layout — WebKit laid nothing out")
            }
            return boxes
        }

        /// **Into `CanvasFileCoordinator.bridgeWorld`, exactly as `pushTool` does**, and
        /// fire-and-forget: the result never comes back in this host (see the type header), and
        /// nothing here needs it. The page world is a different `window`, and using it is #190 —
        /// the global lands where the script cannot see it and every tool is silently `read`.
        private func evaluate(_ javaScript: String) {
            webView.evaluateJavaScript(
                javaScript, in: nil, in: CanvasFileCoordinator.bridgeWorld,
                completionHandler: { _ in })
        }

        /// Highlight an element's contents and release — one evaluation, so the selection and the
        /// `mouseup` that posts it cannot be reordered by a completion this host never delivers.
        ///
        /// **The tool is set here, in the same evaluation, exactly as `markLoop` sets
        /// `.freehand`** — and #302 is why it has to be. This used to say nothing about the tool
        /// and lean on the default being armed for text; that default is now `.read`, which posts
        /// nothing, so the omission stopped being invisible. It did not fail: `marked` waits on a
        /// `withCheckedContinuation` with **no timeout**, so a mark that never arrives hangs the
        /// suite rather than failing it (measured — 12 minutes at 0% CPU before it was killed).
        /// Nothing here relies on an implicit default any more.
        func markSelection(of id: String) async throws {
            let rect = try XCTUnwrap(rects[id], "#\(id) was not in the page's own layout report")
            try await marked {
                evaluate(
                    """
                    (function () {
                      \(CanvasHTML.setMarkTool(.text, theme: .light))
                      var range = document.createRange();
                      range.selectNodeContents(document.getElementById(\(Self.js(id))));
                      var selection = window.getSelection();
                      selection.removeAllRanges();
                      selection.addRange(range);
                      document.dispatchEvent(new MouseEvent("mouseup", {
                        bubbles: true, cancelable: true, button: 0,
                        clientX: \(rect.midX), clientY: \(rect.midY)
                      }));
                    })()
                    """)
            }
        }

        /// What Swift pushes when the comment field closes, issued for real into the same world.
        func clearMark() { evaluate(CanvasHTML.clearMarkScript()) }

        /// Ask the **page's own** world what it can see of helm's mark, and wait for its answer.
        ///
        /// The question is posed by setting an attribute on a shared `document`, because a
        /// bridge-world `evaluateJavaScript` result never comes back in this host (measurement 1
        /// in the type header) — so the page's `postMessage` is the only channel that returns.
        ///
        /// `afterDroppingTheNativeSelection` is the moment under test: `removeAllRanges()` is
        /// what the comment field taking the keyboard does to the browser's own selection, and
        /// helm's mark is a *clone* precisely so that it is not what happens to helm's.
        func reportHighlight(
            afterDroppingTheNativeSelection drop: Bool
        ) async throws
            -> [String: Any]
        {
            let reported = await withCheckedContinuation {
                (continuation: CheckedContinuation<String, Never>) in
                probe.pending = continuation
                evaluate(
                    """
                    (function () {
                      \(drop ? "window.getSelection().removeAllRanges();" : "")
                      document.body.setAttribute("data-helm-ask", "1");
                    })()
                    """)
            }
            return try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(reported.utf8)) as? [String: Any],
                "the page reported nothing readable: \(reported)")
        }

        /// **Asked until it answers, because the two worlds' views of the registry are eventually
        /// consistent rather than instantly so — measured, and it is the surprise this helper
        /// exists for.** A `set` from the bridge world was visible to the page world on the first
        /// question every time; a `delete` was not, and took three round trips to land (measured
        /// 1, 1, 1, 0 across four consecutive asks). A single question after the wipe therefore
        /// fails on timing rather than on behaviour, and asserting the first answer would have
        /// been a flaky test dressed up as a finding.
        ///
        /// It is still waiting on an **observable** rather than on a duration — each round trip
        /// is a real answer from the page — with a bound so a mark that genuinely never goes
        /// fails rather than hanging, which is the failure mode `markSelection`'s header records
        /// costing twelve minutes.
        ///
        /// What lags is the page world's **JavaScript view**. Whether the paint lags with it is
        /// not measurable here and is not claimed: this host renders offscreen.
        func highlightGoes(within asks: Int = 20) async throws -> Bool {
            for _ in 0..<asks {
                let report = try await reportHighlight(afterDroppingTheNativeSelection: false)
                if report["painted"] as? Bool == false { return true }
            }
            return false
        }

        /// A closed-ish loop just outside a real element's real rect, released short of where it
        /// began — a person circling something does not carefully meet the ends. The tool is set
        /// in the same evaluation as the gesture, for `markSelection`'s ordering reason.
        func markLoop(around id: String) async throws {
            let ring = try XCTUnwrap(rects[id], "#\(id) was not in the page's own layout report")
                .insetBy(dx: -6, dy: -6)
            let corners = [
                CGPoint(x: ring.minX, y: ring.minY), CGPoint(x: ring.maxX, y: ring.minY),
                CGPoint(x: ring.maxX, y: ring.maxY), CGPoint(x: ring.minX, y: ring.maxY),
                CGPoint(x: ring.minX, y: ring.minY + 6),
            ]
            let moves = corners.dropFirst().dropLast().map {
                Self.dispatch("mousemove", at: $0)
            }
            try await marked {
                evaluate(
                    """
                    (function () {
                      \(CanvasHTML.setMarkTool(.freehand, theme: .light))
                      \(Self.dispatch("mousedown", at: corners[0]))
                      \(moves.joined(separator: "\n  "))
                      \(Self.dispatch("mouseup", at: corners[corners.count - 1]))
                    })()
                    """)
            }
        }

        /// Run a gesture and wait for the mark to come back **through helm's own bridge** into the
        /// model. Waited on, never slept for: `$selection` becoming non-nil is the observable, and
        /// it is only reachable if the script, the world, the origin gate and
        /// `CanvasPageSelection` all agreed.
        private func marked(_ gesture: () -> Void) async throws {
            let arrived = await withCheckedContinuation {
                (continuation: CheckedContinuation<Bool, Never>) in
                var resumed = false
                marks = model.$selection.sink { selection in
                    guard selection != nil, !resumed else { return }
                    resumed = true
                    continuation.resume(returning: true)
                }
                gesture()
            }
            marks = nil
            XCTAssertTrue(arrived)
        }

        private static func dispatch(_ type: String, at point: CGPoint) -> String {
            """
            document.dispatchEvent(new MouseEvent(\(js(type)), {
              bubbles: true, cancelable: true, button: 0,
              clientX: \(point.x), clientY: \(point.y) }));
            """
        }

        private static func js(_ value: String) -> String {
            let encoded = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
            return String(data: encoded, encoding: .utf8) ?? "\"\""
        }
    }
}
