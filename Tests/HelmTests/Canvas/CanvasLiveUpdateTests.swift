import WebKit
import XCTest

@testable import Helm

/// **The join** (#109): a real `WKWebView` on a real `helm-canvas://` origin, a real artifact
/// rewritten on disk, and the **real** `HTMLCanvasPage.load` deciding what happens to it.
///
/// **Why this cannot be a unit test, stated so nobody trims it back into one.** Everything the
/// feature turns on is WebKit's: whether `evaluateJavaScript(in: .page)` can see a global the
/// *artifact's own* `<script>` defined, whether a page's return value crosses back as something
/// Swift can read, and — the one that decides the whole design — whether a document survives at
/// all when helm chooses not to navigate. None of that is reachable from `CanvasUpdateTests`,
/// and #216 is what happens when both halves are covered separately and the join is not: a
/// decoder that understood geometry marks perfectly, behind a gate that dropped every one of
/// them, with every test on both sides green for months.
///
/// **`window.__mark` is the instrument, and it measures the right thing.** A navigation destroys
/// the JS context, so a value left on `window` surviving **is** "this document was never
/// reloaded" — not a proxy for it, the thing itself. `CanvasSiblingRefreshTests` uses the same
/// probe for the opposite claim, which is what makes it trustworthy in both directions.
///
/// **Why it is safe in the gate**, on `CanvasSiblingFreshnessLiveTests`' terms: no display (a
/// `WKWebView` renders offscreen and nothing here looks at pixels), no network, no TCC grant, no
/// new dependency. It costs about a second.
@MainActor
final class CanvasLiveUpdateTests: XCTestCase {
    private var directory: URL!
    private var artifact: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-live-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        artifact = directory.appendingPathComponent("game.html")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The acceptance, one test each

    /// **A page that registers a handler receives the update as data and is never reloaded.**
    ///
    /// The neovim game, in one test: something interactive is mid-play, the agent rewrites the
    /// artifact, and the page is still there afterwards holding what it had — with the update in
    /// its hands rather than in the bin.
    func testAPageWithAHandlerIsHandedTheUpdateAndKeepsItsDocument() async throws {
        try Self.page(handler: "window.__offers.push(u); return true;").write(
            to: artifact, atomically: true, encoding: .utf8)
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()
        await pane.leaveAMark()

        try Self.page(handler: "window.__offers.push(u); return true;", body: "rewritten").write(
            to: artifact, atomically: true, encoding: .utf8)
        let answer = await pane.rewriteReachedThePage()

        XCTAssertEqual(answer, .applied)
        let survived = await pane.markSurvived()
        XCTAssertTrue(
            survived,
            "the document was reloaded anyway — which is the whole defect: every agent write "
                + "destroys scroll, focus, form input and a half-played game, and a page that "
                + "said it would take the update as data got taken away regardless")
        let offers = await pane.offers()
        XCTAssertEqual(offers.count, 1, "exactly one offer for one rewrite")
        XCTAssertEqual(
            offers.first?["kind"] as? String, "canvas.update",
            "the page is handed a payload that says what it is, from the first message — the "
                + "acceptance item #216 is the bill for not having")
        XCTAssertEqual(offers.first?["artifact"] as? String, "game.html")
        XCTAssertEqual(
            offers.first?["generation"] as? Int, 1,
            "and which update it is, so a page can tell two apart")
    }

    /// **A page with no handler still reloads, exactly as today.**
    ///
    /// The control for the test above: if this went the other way, "never reloaded" would be
    /// satisfied by never reloading anything, and every plain artifact would silently stop
    /// updating.
    func testAPageWithNoHandlerReloadsExactlyAsItAlwaysDid() async throws {
        try Self.page(handler: nil).write(to: artifact, atomically: true, encoding: .utf8)
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()
        await pane.leaveAMark()

        try Self.page(handler: nil, body: "rewritten").write(
            to: artifact, atomically: true, encoding: .utf8)
        let answer = await pane.rewriteReachedThePage()

        XCTAssertEqual(answer, .unhandled)
        let survived = await pane.markSurvived()
        XCTAssertFalse(
            survived,
            "a page with nothing to take the update must be reloaded — anything else is an "
                + "artifact that quietly stops updating, which is worse than the reload")
        let body = await pane.bodyText()
        XCTAssertEqual(
            body, "rewritten",
            "and it must be the NEW bytes on screen, not merely a navigation that happened")
    }

    /// **A reload that would discard interactive state shows the notice instead of reloading.**
    ///
    /// `return false` is the page saying *not now* — mid-play, mid-typing — and helm answers by
    /// keeping the page and putting the choice on the strip. The gate is on the destructive
    /// action, which is the rule this ticket argues nobody else has shipped.
    func testAPageThatDeclinesKeepsItsDocumentAndTheOperatorGetsTheChoice() async throws {
        try Self.page(handler: "window.__offers.push(u); return false;").write(
            to: artifact, atomically: true, encoding: .utf8)
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()
        await pane.leaveAMark()

        try Self.page(handler: "window.__offers.push(u); return false;", body: "rewritten").write(
            to: artifact, atomically: true, encoding: .utf8)
        let answer = await pane.rewriteReachedThePage()

        XCTAssertEqual(answer, .declined)
        let survived = await pane.markSurvived()
        XCTAssertTrue(survived, "a decline must not be overridden by helm")
        XCTAssertNotNil(
            answer?.notice, "and the operator must be told, or the canvas is silently stale")

        // The operator answers it. This is the ONLY route from a decline to a reload.
        pane.reloadOnDemand(1)
        let survivedTheReload = await pane.markSurvived()
        XCTAssertFalse(
            survivedTheReload,
            "Reload must actually reload — a notice with a dead button is worse than no notice")
        let reloadedBody = await pane.bodyText()
        XCTAssertEqual(reloadedBody, "rewritten")
    }

    /// A handler that throws is still a page holding state. helm keeps it and says why — it does
    /// **not** tidy up by reloading, which would destroy exactly what the handler existed to
    /// protect, and it does not swallow the reason.
    func testAHandlerThatThrowsKeepsThePageAndCarriesItsOwnReason() async throws {
        let thrower = #"throw new Error("state is not JSON");"#
        try Self.page(handler: thrower).write(to: artifact, atomically: true, encoding: .utf8)
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()
        await pane.leaveAMark()

        try Self.page(handler: thrower, body: "rewritten").write(
            to: artifact, atomically: true, encoding: .utf8)
        let answer = await pane.rewriteReachedThePage()

        XCTAssertEqual(answer, .failed("state is not JSON"))
        let survived = await pane.markSurvived()
        XCTAssertTrue(survived)
        XCTAssertTrue(
            try XCTUnwrap(answer?.notice).contains("state is not JSON"),
            "the page's own message, or the operator is told only that something went wrong")
    }

    /// **A control, and the one that says the offer did not overshoot.** A first load has no page
    /// to offer anything to, so it must navigate outright — an offer there would evaluate against
    /// a document that does not exist yet, get `unhandled`, and reload: the same answer by
    /// accident rather than by rule, which is exactly the kind of thing that works until it does
    /// not. It passes before the change too, because before it every load navigated.
    func testTheFirstLoadStillNavigatesWithNoOfferAtAll() async throws {
        try Self.page(handler: "window.__offers.push(u); return true;").write(
            to: artifact, atomically: true, encoding: .utf8)
        let pane = try Pane(artifact: artifact)

        try await pane.firstLoad()

        let body = await pane.bodyText()
        XCTAssertEqual(body, "original", "the page is up")
        let offered = await pane.offers().count
        XCTAssertEqual(
            offered, 0, "nothing was offered — there was no previous document to keep")
    }

    /// **The second control: a theme flip must navigate even on a page with a handler.**
    ///
    /// It is the case an "always offer" rule gets wrong, and gets wrong silently. The mermaid
    /// theme and the artifact init script are `WKUserScript`s, re-armed by `navigate` and taken
    /// into effect only by a navigation — so a page that "applied" a theme flip would keep
    /// rendering its diagrams in the old theme with nothing anywhere reporting a problem.
    func testAThemeFlipNavigatesEvenThoughThePageHasAHandler() async throws {
        try Self.page(handler: "window.__offers.push(u); return true;").write(
            to: artifact, atomically: true, encoding: .utf8)
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()
        await pane.leaveAMark()

        pane.render(generation: 0, theme: .light)

        let survived = await pane.markSurvived(timeout: .seconds(3))
        XCTAssertFalse(
            survived,
            "a theme flip re-arms the injected scripts, and only a navigation applies them — "
                + "offering it to the page would leave the diagrams in the old theme forever")
        let offered = await pane.offers().count
        XCTAssertEqual(offered, 0, "and it is not an update, so nothing was offered")
    }

    /// **A demand is a rise, not a value — and a rebuilt pane must not read the model's history
    /// as a fresh press.** Found by review, and it is the counter-desync `AGENTS.md` warns about
    /// twice over.
    ///
    /// `CanvasModel.reloadDemand` outlives the coordinator by design — the model belongs to the
    /// pane and the coordinator to SwiftUI, which rebuilds `HTMLCanvasWebView` whenever the
    /// operator switches tabs away and back. A coordinator that started its own counter at zero
    /// would then mismatch a model standing at 1 and navigate a second time, immediately after
    /// `makeNSView` had just loaded the page — on **every** future revisit, not once.
    ///
    /// The seeding itself lives in `HTMLCanvasWebView.makeCoordinator`, which no test can reach
    /// (`NSViewRepresentableContext` has no public initializer), so what this pins is the rule
    /// the seeding relies on: **handed the demand it was seeded with, `reloadOnDemand` does
    /// nothing.** Without that, seeding would be pointless; without the seeding, the app hands
    /// it a value it was not seeded with. The second half — that a demand it has NOT seen does
    /// navigate — is `testAPageThatDeclinesKeepsItsDocumentAndTheOperatorGetsTheChoice`, so
    /// between them the counter cannot be satisfied by ignoring every demand.
    func testACoordinatorRebuiltAfterAReloadDoesNotReloadAgainByItself() async throws {
        try Self.page(handler: "window.__offers.push(u); return true;").write(
            to: artifact, atomically: true, encoding: .utf8)

        // The operator pressed Reload once, some time ago; SwiftUI has since rebuilt the view.
        let pane = try Pane(artifact: artifact, reloadDemand: 1)
        try await pane.firstLoad()
        await pane.leaveAMark()

        // What `updateNSView` does on the very next render, with nothing having happened.
        pane.reloadOnDemand(1)

        let survived = await pane.markSurvived()
        XCTAssertTrue(
            survived,
            "the page was loaded a second time for a press nobody made — a counter compared "
                + "against a fresh coordinator's guess of zero rather than against what the "
                + "model actually stands at")
    }

    // MARK: - The picture on a page that was never reloaded (#279)

    /// **The branch nothing else could ever have reached.** A page with a handler keeps its
    /// document forever by contract, so the edited `./probe.svg` beside it has no navigation
    /// coming to refresh it — which is the whole reason #279 is a re-stamp rather than a rebuilt
    /// webview. A rebuild reaches only the `navigate()` branch, so on this page it would do
    /// nothing at all, for as long as the operator kept it open.
    ///
    /// Both halves are asserted together, because either alone is satisfied by the wrong fix:
    /// the picture is the new one **and** the document was never taken away.
    func testAPageThatKeepsItsDocumentStillGetsTheEditedPicture() async throws {
        let sibling = directory.appendingPathComponent("probe.svg")
        try Self.svg(width: 11).write(to: sibling, atomically: true, encoding: .utf8)
        let handler = "window.__offers.push(u); return true;"
        try Self.page(handler: handler, body: Self.picture).write(
            to: artifact, atomically: true, encoding: .utf8)

        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()
        await pane.leaveAMark()
        let before = await pane.imageWidth(settlingOn: "11")
        XCTAssertEqual(before, "11", "precondition: the picture is on the page at all")

        // The agent regenerates the diagram and rewrites the artifact. The `<img>` tag is
        // byte-identical across the rewrite, exactly as it is in real life.
        try Self.svg(width: 22).write(to: sibling, atomically: true, encoding: .utf8)
        try Self.page(handler: handler, body: Self.picture + "rewritten").write(
            to: artifact, atomically: true, encoding: .utf8)
        let answer = await pane.rewriteReachedThePage()
        XCTAssertEqual(answer, .applied, "precondition: the page took the update")

        let after = await pane.imageWidth(settlingOn: "22")
        XCTAssertEqual(
            after, "22",
            "the page applied the update and refetched its state, and the one thing it cannot "
                + "refresh for itself is a picture WebKit already decoded under that URL. `11` "
                + "is a canvas showing a diagram that no longer exists on disk")
        let survived = await pane.markSurvived()
        XCTAssertTrue(
            survived,
            "and it must still be the same document — a re-stamp that reached the picture by "
                + "reloading the page would have destroyed exactly what the handler protects")
    }

    // MARK: - The artifact

    /// An `.html` artifact, optionally holding state and taking updates. `__offers` is the page's
    /// own record of what helm handed it — the far side of the payload, read back verbatim.
    private static func page(handler: String?, body: String = "original") -> String {
        let registration =
            handler.map {
                """
                window.__offers = [];
                window.helmCanvasUpdate = function (u) { \($0) };
                """
            } ?? "window.__offers = [];"
        return """
            <!doctype html><html><body>\(body)<script>
            \(registration)
            window.webkit.messageHandlers.probe.postMessage("loaded");
            </script></body></html>
            """
    }

    /// A regenerated diagram beside the artifact, which is the ordinary shape an agent produces.
    private static let picture = #"<img src="./probe.svg">"#

    /// A sibling image whose width says which version of it the page got. SVG because it is
    /// text, and `naturalWidth` reads the declared width — the same instrument
    /// `CanvasSiblingRefreshTests` and `CanvasSiblingFreshnessLiveTests` use.
    private static func svg(width: Int) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(width)">\
        <rect width="\(width)" height="\(width)" fill="#7cf"/></svg>
        """
    }

    // MARK: - The pane that hosts it

    /// The **real** webview `HTMLCanvasWebView` builds, loaded by the **real** rule it loads by,
    /// with one test-only `probe` handler so the page can say it is up.
    ///
    /// `probe` is registered in the **page** content world deliberately: helm's own bridge lives
    /// in `CanvasFileCoordinator.bridgeWorld` precisely so an artifact's JavaScript cannot reach
    /// it, and this harness is standing in for the artifact.
    @MainActor
    private final class Pane: NSObject, WKScriptMessageHandler {
        private let path: StandardizedPath
        private let coordinator: CanvasFileCoordinator
        private let webView: WKWebView
        private var loads = 0
        /// Every answer the coordinator reported, which is what `CanvasModel.pageAnsweredUpdate`
        /// receives in the app.
        private var answers: [CanvasUpdateAnswer] = []

        /// - Parameter reloadDemand: what the model's counter already stood at when this
        ///   coordinator was made — `HTMLCanvasWebView.makeCoordinator`'s seeding, reproduced.
        ///   Zero is the ordinary case; anything else is a pane whose operator has pressed
        ///   Reload before and whose view SwiftUI has since rebuilt.
        init(artifact: URL, reloadDemand: Int = 0) throws {
            path = StandardizedPath(artifact.path)
            coordinator = CanvasFileCoordinator(
                host: CanvasAddress.host(for: path), onAnnotation: { _ in })
            webView = HTMLCanvasPage.makeWebView(for: path, coordinator: coordinator)
            super.init()
            coordinator.onUpdate = { [weak self] in self?.answers.append($0) }
            coordinator.reloadDemand = reloadDemand
            webView.configuration.userContentController.add(self, name: "probe")
        }

        /// What SwiftUI's `updateNSView` does: hand the view the document's current generation
        /// and let the view's own rule decide what that means. Driving `HTMLCanvasPage.load`
        /// rather than `webView.load` is the point — the decision under test is that rule's.
        func render(generation: Int, theme: CanvasTheme = .dark) {
            HTMLCanvasPage.load(
                webView, path: path, generation: generation, theme: theme,
                coordinator: coordinator)
        }

        /// The operator pressing Reload on the notice.
        func reloadOnDemand(_ demand: Int, theme: CanvasTheme = .dark) {
            HTMLCanvasPage.reloadOnDemand(
                demand, webView, path: path, theme: theme, coordinator: coordinator)
        }

        func firstLoad() async throws {
            render(generation: 0)
            try await waitForLoad(count: 1)
        }

        /// Rewrite landed: bump the generation the way `CanvasModel.refresh()` does, then wait
        /// for the answer the offer produced. **nil is a real answer** — it is "helm never
        /// asked the page anything", which is the feature not running at all.
        func rewriteReachedThePage(timeout: Duration = .seconds(5)) async -> CanvasUpdateAnswer? {
            render(generation: 1)
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let answer = answers.last { return answer }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return nil
        }

        /// Leave something on `window` that a navigation destroys.
        func leaveAMark() async { _ = await ask("window.__helmTestMark = 1; 'ok'") }

        /// Whether this is still the same document. Polls for the mark going AWAY, so a slow
        /// navigation is not read as a page that survived — the answer only settles at the
        /// deadline when nothing navigated, which is the state the passing tests assert.
        func markSurvived(timeout: Duration = .seconds(2)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if await ask("String(!!window.__helmTestMark)") == "false" { return false }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return true
        }

        /// What helm handed the page, read out of the page's own record.
        func offers() async -> [[String: Any]] {
            let json = await ask("JSON.stringify(window.__offers || [])")
            let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8))
            return (parsed as? [[String: Any]]) ?? []
        }

        func bodyText() async -> String {
            await ask("document.body.innerText.trim()")
        }

        /// What the page's `<img>` decoded to — which version of the picture is on screen (#279),
        /// read off the element and never off a pixel. Polled, because helm's re-stamp is an
        /// `evaluateJavaScript` that then has to be fetched and decoded; returns whatever it last
        /// saw, so a failure names the width rather than saying only that it never arrived.
        func imageWidth(settlingOn wanted: String, timeout: Duration = .seconds(5)) async -> String
        {
            let script = "String((document.querySelector('img') || {}).naturalWidth)"
            let deadline = ContinuousClock.now + timeout
            var last = ""
            while ContinuousClock.now < deadline {
                last = await ask(script)
                if last == wanted { return last }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return last
        }

        private func waitForLoad(count: Int, timeout: Duration = .seconds(5)) async throws {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if loads >= count { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("the page never loaded — this test's precondition, not its subject")
        }

        private func ask(_ script: String) async -> String {
            await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(script) { value, _ in
                    continuation.resume(returning: value as? String ?? "")
                }
            }
        }

        nonisolated func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            MainActor.assumeIsolated { loads += 1 }
        }
    }
}
