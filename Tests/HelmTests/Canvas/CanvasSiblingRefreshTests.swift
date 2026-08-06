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
