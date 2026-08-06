import WebKit
import XCTest

@testable import Helm

/// **The join** (#261): a real push through the real `WorkbenchModel`, onto a real page.
///
/// Editing only a sibling — `app.js`, `data.json` — did nothing, and pushing the canvas again
/// did nothing either. Two halves, neither wrong alone:
///
/// - `CanvasModel.open` watches **one** url, the artifact. A sibling changing is not an event.
/// - `WorkbenchModel.offer` returned the existing pane untouched, on the reasoning that
///   *"`FileWatcher` has already re-rendered that pane"* — true of the artifact, false of
///   everything beside it. So for a sibling-only edit the one path left declined on the
///   strength of a refresh that never happened.
///
/// **Both sides worked in isolation, which is why nothing caught it.** `CanvasSchemeHandler`
/// serves a sibling correctly (`CanvasSchemeHandlerTests`), WebKit fetches a fresh one
/// (`CanvasSiblingFreshnessLiveTests` — six ways, no staleness, which is what closed #228), and
/// `Workbench.offer` places a pane correctly (`WorkbenchOfferTests`). Every one of those stayed
/// green throughout. That is #216's shape exactly, so the test that was missing is the one that
/// spans the whole distance: **a push in at one end, and what the page ends up with read off the
/// other**.
///
/// It drives the app's own objects the whole way. `HelmCommand.pushCanvasFile` is the command a
/// terminal's OSC 777 posts; `HTMLCanvasPage` is the very configuration and reload rule
/// `HTMLCanvasWebView` gives SwiftUI. The one thing standing in for the app is SwiftUI itself —
/// `render(_:)` below is what `updateNSView` does when the model publishes, and nothing more.
///
/// **Why it is safe in the gate**, on `CanvasSiblingFreshnessLiveTests`' terms: no display (a
/// `WKWebView` renders offscreen and nothing here looks at pixels), no network, no TCC grant, no
/// new dependency. It costs about a second.
@MainActor
final class CanvasSiblingRefreshTests: XCTestCase {
    private var directory: URL!
    private var artifact: URL!
    private var sibling: URL!
    private var other: URL!

    private let workspace = WorkspacePath("/tmp/helm-canvas-sibling-refresh")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-sibling-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        artifact = directory.appendingPathComponent("page.html")
        sibling = directory.appendingPathComponent("data.json")
        other = directory.appendingPathComponent("elsewhere.html")
        try Self.pageThatReportsItsSibling.write(to: artifact, atomically: true, encoding: .utf8)
        try "<!doctype html><html><body>elsewhere</body></html>"
            .write(to: other, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Across the join, with a live page

    /// **The regression test.** Edit only the sibling, push the same artifact again, and the
    /// bytes the page holds are the new ones.
    ///
    /// The artifact is never touched, so the `FileWatcher` correctly fires nothing — that half
    /// is not a bug and is not being worked around here. The push is the only signal helm gets.
    func testARePushAfterASiblingOnlyEditPutsTheNewBytesOnThePage() async throws {
        try #"{"version":"v1"}"#.write(to: sibling, atomically: true, encoding: .utf8)

        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        try await push(artifact, from: terminal.id)

        let canvas = try openCanvas(in: model)
        let page = LivePane(artifact: artifact)
        page.render(try document(of: canvas))
        let first = await page.nextReport()
        XCTAssertEqual(
            first, #"{"version":"v1"}"#,
            "precondition: the sibling is served at all — if this fails the rest measures nothing")

        // ONLY the sibling. `page.html` keeps its mtime and its bytes.
        try #"{"version":"v2"}"#.write(to: sibling, atomically: true, encoding: .utf8)

        try await push(artifact, from: terminal.id)
        page.render(try document(of: canvas))

        let second = await page.nextReport()
        XCTAssertEqual(
            second, #"{"version":"v2"}"#,
            "a re-push after a sibling edit must put the new bytes on the page. **nil is #261 "
                + "itself** — `offer` returned `.existing` without refreshing, so the document's "
                + "generation never moved, so the view's load rule saw no change and never "
                + "navigated, and the page never said anything again. `v1` would be a different "
                + "bug: a navigation that happened and got stale bytes, which is #228's "
                + "diagnosis and was disproved six ways")
    }

    /// Editing the **artifact** must still reach the page, and by the route it always did — the
    /// pane's own `FileWatcher`, with no push at all.
    ///
    /// **A control: it passes before and after the fix.** It is here because the fix is a second
    /// caller of `CanvasModel.refresh()`, and a change that made the push path work by breaking
    /// the watcher path would otherwise pass everything above.
    func testEditingTheArtifactItselfStillReloadsThePaneWithNoPush() async throws {
        try #"{"version":"v1"}"#.write(to: sibling, atomically: true, encoding: .utf8)

        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        try await push(artifact, from: terminal.id)

        let canvas = try openCanvas(in: model)
        let page = LivePane(artifact: artifact)
        page.render(try document(of: canvas))
        let first = await page.nextReport()
        XCTAssertEqual(first, #"{"version":"v1"}"#, "precondition")

        try #"{"version":"v2"}"#.write(to: sibling, atomically: true, encoding: .utf8)
        // Touching the artifact is what the `?v=2` workaround was really doing (#228). Here it
        // is done honestly — a rewrite of the file the watcher is on.
        try (Self.pageThatReportsItsSibling + "\n<!-- rewritten -->\n")
            .write(to: artifact, atomically: true, encoding: .utf8)
        try await settle(untilGenerationRises: canvas)
        page.render(try document(of: canvas))

        let second = await page.nextReport()
        XCTAssertEqual(
            second, #"{"version":"v2"}"#,
            "the artifact's own watcher is the route that always worked; the fix must not cost it")
    }

    /// **The same bug, in a markdown canvas** — where it is much easier to miss.
    ///
    /// `CanvasSchemeHandler` resolves a relative request against the artifact's directory with no
    /// branch on content type, so `![probe](./probe.svg)` in a `.md` artifact is served over
    /// exactly the path an `.html` artifact's `<script src>` is. Every other test in this file is
    /// `.html`-shaped, and the fix is only symmetric because `CanvasModel.refresh()` does not
    /// discriminate — nothing pinned that down until this.
    ///
    /// **The markdown text is byte-identical across the re-push, deliberately.**
    /// `MarkdownCanvasPage`'s reload key already carries the whole document string, so a
    /// `generation` beside it reads as redundant and is not: with the source unchanged, the
    /// counter is the only term that can differ. Drop it — the tidy-up `CanvasReloadKey` exists to
    /// make unwritable — and this is what goes red.
    ///
    /// The document is asked whether it is a **new** document (`window` is destroyed by a
    /// navigation, so a mark set on the old one is gone) and then asked what the sibling says
    /// now. Both, because either alone is ambiguous: a fresh mark with stale bytes and a stale
    /// mark with fresh bytes are different bugs.
    ///
    /// **A measured aside, because it cost an hour and would cost the next reader the same.**
    /// The obvious probe here — put `![probe](./probe.svg)` in the markdown and read
    /// `naturalWidth` — reports the **old** width after a reload that demonstrably happened:
    /// `window.__mark` is gone and a `fetch` of the identical URL returns the new bytes, so the
    /// handler is serving correctly and WebKit is reusing its in-memory copy of the *image*. It
    /// clears on a second webview (a new pane, a relaunch), which is why nothing about it
    /// survives a restart. That is a real effect and it is **not** #261 — the pane does reload,
    /// which is all this fix claims — so it is recorded here rather than asserted, and it wants
    /// a ticket of its own.
    func testARePushRefreshesAMarkdownCanvasSiblingToo() async throws {
        let markdownArtifact = directory.appendingPathComponent("report.md")
        let sibling = directory.appendingPathComponent("probe.svg")
        let source = "# Report\n\n![probe](./probe.svg)\n"
        try Self.svg(width: 11).write(to: sibling, atomically: true, encoding: .utf8)
        try source.write(to: markdownArtifact, atomically: true, encoding: .utf8)

        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        try await push(markdownArtifact, from: terminal.id)

        let canvas = try self.canvas(showing: markdownArtifact, in: model)
        let page = LiveMarkdownPane(artifact: markdownArtifact)
        page.render(try document(of: canvas), markdown: source)
        await page.waitForRender()
        let first = await page.siblingText()
        XCTAssertTrue(
            first.contains(#"width="11""#),
            "precondition: a markdown canvas serves a sibling at all — got \(first)")
        await page.mark()

        // ONLY the sibling. `report.md` is not rewritten, so its text is the same string in both
        // reload keys and the `FileWatcher` on it fires nothing at all.
        try Self.svg(width: 22).write(to: sibling, atomically: true, encoding: .utf8)

        try await push(markdownArtifact, from: terminal.id)
        page.render(try document(of: canvas), markdown: source)

        let navigated = await page.didNavigateAwayFromTheMarkedDocument()
        XCTAssertTrue(
            navigated,
            "the re-push must give the pane a NEW document. The mark surviving means this webview "
                + "never navigated — and markdown is where that is easiest to reintroduce: the "
                + "reload key already carries the whole source, so dropping `generation` beside it "
                + "reads as a cleanup, and with a byte-identical source the counter is the only "
                + "term left that can differ")
        await page.waitForRender()
        let second = await page.siblingText()
        XCTAssertTrue(
            second.contains(#"width="22""#),
            "and the new document must get the new sibling bytes — got \(second)")
    }

    // MARK: - The bench half, without WebKit

    /// The same fact one layer down and a hundred times cheaper: `Document.generation` is the
    /// only thing that can say *"the same path, different bytes"*, and it is what
    /// `HTMLCanvasPage.load` keys its navigation on.
    func testARePushOfAnOpenCanvasBumpsItsDocumentGeneration() async throws {
        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        try await push(artifact, from: terminal.id)

        let canvas = try openCanvas(in: model)
        let before = try document(of: canvas).generation

        try await push(artifact, from: terminal.id)

        XCTAssertGreaterThan(
            try document(of: canvas).generation, before,
            "a re-push is a request to show that file again; a generation that never moves is a "
                + "pane that never re-renders")
    }

    /// **A control, and the one that says the fix did not overshoot.** *Appear, don't seize*
    /// (#125) is about `selected` and `focusedSlot`, and a refresh touches neither: the operator
    /// is reading another tab in the same slot, and a re-push of the tab behind it must not pull
    /// it forward.
    ///
    /// It passes before the fix too — before it, nothing happened at all — which is exactly what
    /// makes it a control rather than evidence.
    func testARePushStillDoesNotChangeWhatTheSlotShowsOrWhereFocusIs() async throws {
        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        try await push(artifact, from: terminal.id)
        // Resolved, so the re-push below really does refresh something — an unresolved pane
        // has no render to disturb and would satisfy this for the wrong reason.
        _ = try openCanvas(in: model)

        // The operator opens a second canvas by hand. `open` seizes, correctly — it is their
        // gesture — so this is what the push must now leave alone.
        XCTAssertNotNil(model.open(.file(other)))
        let showing = try XCTUnwrap(model.bench?.focusedPane?.id)
        let focused = try XCTUnwrap(model.bench?.focusedSlot)

        try await push(artifact, from: terminal.id)

        XCTAssertEqual(
            model.bench?.focusedPane?.id, showing,
            "the operator was reading elsewhere.html — a re-push may re-render the tab behind "
                + "it, never replace it")
        XCTAssertEqual(model.bench?.focusedSlot, focused)
        XCTAssertEqual(model.bench?.canvasPanes.count, 2, "and no third copy")
    }

    /// **A control against the other overshoot**: refreshing every canvas on the bench, rather
    /// than the one that was pushed, would satisfy every assertion above.
    func testPushingOneArtifactDoesNotRefreshAnother() async throws {
        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        try await push(artifact, from: terminal.id)
        try await push(other, from: terminal.id)

        // Both resolved: a refresh only reaches a pane that has a `CanvasModel`, so leaving the
        // pushed one unresolved would make this pass without the fix ever running.
        _ = try openCanvas(in: model)
        let bystander = try canvas(showing: other, in: model)
        let before = try document(of: bystander).generation

        try await push(artifact, from: terminal.id)

        XCTAssertEqual(
            try document(of: bystander).generation, before,
            "elsewhere.html was not pushed; re-rendering it would discard a scroll position "
                + "nobody asked to lose")
    }

    // MARK: - The bench, and a push into it

    private func mounted() -> (WorkbenchModel, TerminalManager) {
        let manager = TerminalManager()
        let model = WorkbenchModel(terminals: manager)
        model.activate(workspacePath: workspace)
        return (model, manager)
    }

    /// The command a terminal's OSC 777 posts, and the hop onto the bench it travels over —
    /// `HelmCommand.publisher` delivers on the main queue, so the sleep is what lets it land.
    private func push(_ file: URL, from terminal: UUID) async throws {
        HelmCommand.pushCanvasFile(
            CanvasPushRequest(
                artifact: file, workspacePath: workspace,
                origin: CanvasOrigin(terminal: terminal))
        ).post()
        try await Task.sleep(for: .milliseconds(100))
    }

    private func openCanvas(in model: WorkbenchModel) throws -> CanvasModel {
        try canvas(showing: artifact, in: model)
    }

    private func canvas(showing file: URL, in model: WorkbenchModel) throws -> CanvasModel {
        let bench = try XCTUnwrap(model.bench, "no bench — the workspace never activated")
        let id = try XCTUnwrap(
            bench.pane(showing: .file(file)), "no canvas pane is showing \(file.lastPathComponent)")
        return model.canvas(for: try XCTUnwrap(bench.pane(id)))
    }

    private func document(of canvas: CanvasModel) throws -> CanvasModel.Document {
        try XCTUnwrap(
            { if case let .file(document) = canvas.showing { document } else { nil } }(),
            "the canvas is not showing a file")
    }

    /// The `FileWatcher` is a `DispatchSource` on the main queue, so its callback lands on a
    /// later turn of the run loop than the write. Polls for the effect rather than sleeping a
    /// guessed interval.
    private func settle(untilGenerationRises canvas: CanvasModel) async throws {
        let before = try document(of: canvas).generation
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if try document(of: canvas).generation > before { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail(
            "the artifact's own watcher never fired — this test's precondition, not its subject")
    }

    // MARK: - The page, and the pane that hosts it

    /// Reports what it got, whatever it got, on every load. A 404 is reported as such rather
    /// than thrown, so a page that reloaded and found nothing is told apart from one that never
    /// reloaded at all.
    private static let pageThatReportsItsSibling = """
        <!doctype html><html><body><script>
        fetch('./data.json')
          .then(r => r.ok ? r.text() : Promise.resolve('MISSING ' + r.status))
          .catch(e => 'THREW ' + e)
          .then(t => window.webkit.messageHandlers.probe.postMessage(String(t).trim()));
        </script></body></html>
        """

    /// A sibling image whose width says which version of it the page got. SVG rather than a
    /// raster format because it is text, and `naturalWidth` reads the declared width.
    private static func svg(width: Int) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(width)">\
        <rect width="\(width)" height="\(width)" fill="#7cf"/></svg>
        """
    }

    /// The markdown canvas's twin of `LivePane` — the **real** webview `MarkdownCanvasWebView`
    /// builds, loaded by the **real** rule it loads by.
    ///
    /// It asks the page a question instead of being told one: helm generates a markdown
    /// canvas's page, so there is no inline script of the author's to post from, and
    /// `evaluateJavaScript` in the **page** world is how a test reads what rendered.
    @MainActor
    private final class LiveMarkdownPane {
        private let path: StandardizedPath
        private let coordinator: CanvasFileCoordinator
        private let webView: WKWebView

        init(artifact: URL) {
            path = StandardizedPath(artifact.path)
            coordinator = CanvasFileCoordinator(
                host: CanvasAddress.host(for: path), onAnnotation: { _ in })
            webView = MarkdownCanvasPage.makeWebView(for: path, coordinator: coordinator)
        }

        /// What SwiftUI's `updateNSView` does. The markdown is passed in rather than re-read so
        /// the test can hold it constant across a re-push, which is the case that matters.
        func render(_ document: CanvasModel.Document, markdown: String, theme: CanvasTheme = .dark)
        {
            MarkdownCanvasPage.load(
                webView, path: path, markdown: markdown, generation: document.generation,
                theme: theme, coordinator: coordinator)
        }

        /// Leave something on `window` that a navigation destroys.
        func mark() async { _ = await ask("window.__helmTestMark = 1; 'ok'") }

        /// Wait for the document helm generates to have rendered the markdown — the `<img>` the
        /// source names only exists once `marked` has run, so it is the signal that the page is
        /// there and answering.
        func waitForRender(timeout: Duration = .seconds(5)) async {
            await poll(until: "String(!!document.querySelector('img'))", equals: "true", timeout)
        }

        /// Whether the webview really navigated: `window` does not survive a navigation, so the
        /// mark left on the previous document going away **is** the new document arriving.
        /// False after the deadline means no navigation happened at all, which is #261's shape.
        func didNavigateAwayFromTheMarkedDocument(timeout: Duration = .seconds(5)) async -> Bool {
            await poll(until: "String(!!window.__helmTestMark)", equals: "false", timeout)
        }

        private func poll(
            until script: String, equals wanted: String, _ timeout: Duration
        ) async
            -> Bool
        {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if await ask(script) == wanted { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return false
        }

        /// What the page gets when it asks for its sibling **now** — the real fetch, over the
        /// real handler, from whatever document is currently loaded.
        func siblingText() async -> String {
            await withCheckedContinuation { continuation in
                webView.callAsyncJavaScript(
                    """
                    const r = await fetch('./probe.svg');
                    return r.ok ? await r.text() : 'HTTP ' + r.status;
                    """,
                    arguments: [:], in: nil, in: .page
                ) { result in
                    switch result {
                    case let .success(value): continuation.resume(returning: value as? String ?? "")
                    case let .failure(error):
                        continuation.resume(returning: "THREW \(error.localizedDescription)")
                    }
                }
            }
        }

        private func ask(_ script: String) async -> String {
            await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(script) { value, _ in
                    continuation.resume(returning: value as? String ?? "")
                }
            }
        }
    }

    /// A canvas pane's page: the **real** webview `HTMLCanvasWebView` builds, loaded by the
    /// **real** rule it loads by, with one test-only `probe` handler added so the page can say
    /// what it fetched.
    ///
    /// `probe` is registered in the **page** content world, deliberately: helm's own bridge
    /// lives in `CanvasFileCoordinator.bridgeWorld` precisely so an artifact's JavaScript cannot
    /// reach it, and this harness is standing in for the artifact.
    @MainActor
    private final class LivePane: NSObject, WKScriptMessageHandler {
        private let path: StandardizedPath
        private let coordinator: CanvasFileCoordinator
        private let webView: WKWebView
        private var reported: [String] = []

        init(artifact: URL) {
            path = StandardizedPath(artifact.path)
            coordinator = CanvasFileCoordinator(
                host: CanvasAddress.host(for: path), onAnnotation: { _ in })
            webView = HTMLCanvasPage.makeWebView(for: path, coordinator: coordinator)
            super.init()
            webView.configuration.userContentController.add(self, name: "probe")
        }

        /// What SwiftUI's `updateNSView` does when the canvas model publishes: hand the view
        /// the document's current generation and let the view's own rule decide whether that is
        /// a reload. It is not this harness's decision, and that is the point of driving
        /// `HTMLCanvasPage.load` rather than `webView.load`.
        func render(_ document: CanvasModel.Document, theme: CanvasTheme = .dark) {
            HTMLCanvasPage.load(
                webView, path: path, generation: document.generation, theme: theme,
                coordinator: coordinator)
        }

        /// The next thing the page says, or nil if it says nothing before `timeout`.
        ///
        /// **nil is a real answer, not a flake budget.** It is what "the pane never reloaded"
        /// looks like from outside the process, and it is the failure #261 actually is — so the
        /// assertion that reads it says so rather than hanging on a continuation nobody will
        /// resume.
        func nextReport(timeout: Duration = .seconds(5)) async -> String? {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if !reported.isEmpty { return reported.removeFirst() }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return reported.isEmpty ? nil : reported.removeFirst()
        }

        nonisolated func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            let body = message.body as? String ?? ""
            MainActor.assumeIsolated { reported.append(body) }
        }
    }
}
