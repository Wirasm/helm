import CanvasKit
import WebKit
import XCTest

@testable import Helm

/// **The join** (#532): a real `WKWebView` built by the **real** `HTMLCanvasPage.makeWebView`, a
/// real `.html` artifact on a real `helm-canvas://` origin, and the artifact's **own** script
/// writing its live file through `helmCanvasData` and hearing the agent's write through
/// `helmCanvasUpdate`, wired to the **real** `CanvasModel`.
///
/// Everything the channel turns on is WebKit's: whether a page-world script reaches a reply
/// handler registered in `WKContentWorld.page` and gets its promise answered, whether it still
/// cannot reach the annotation bridge in `CanvasFileCoordinator.bridgeWorld`, and whether an
/// update offer carries the live file's name to the page. `LiveFileTests` cannot see any of that.
///
/// **Safe in the gate**, on `CanvasLiveUpdateTests`' terms: no display, no network, no TCC grant.
@MainActor
final class CanvasLiveFileLiveTests: XCTestCase {
    private var directory: URL!
    private var artifact: URL!
    private var data: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-live-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        artifact = directory.appendingPathComponent("tasks.html")
        data = directory.appendingPathComponent("tasks.data.json")
        try Self.page.write(to: artifact, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// **The control that lets a page-world handler exist at all**: on one page, in one run, the
    /// page reaches `helmCanvasData` and still cannot reach the annotation bridge, so it can write
    /// its own data and cannot forge the operator's mark (#164).
    func testThePageReachesItsDataChannelAndStillCannotReachTheAnnotationBridge() async throws {
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()

        let channel = await pane.visible(CanvasDataWrite.handlerName)
        let bridge = await pane.visible(CanvasFileCoordinator.bridgeHandlerName)
        XCTAssertTrue(channel, "the page must be able to write — that is the whole slice")
        XCTAssertFalse(
            bridge, "an artifact that can reach the annotation bridge can forge an operator's mark")
    }

    /// **The page writes, and the file holds it**, and the page's promise says so with the text.
    /// Then a write from a version the page has not seen is answered with what is there, and
    /// writes nothing.
    func testAPageWriteLandsAndAStaleOneIsAnsweredWithTheNewerFile() async throws {
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()

        let written = try await pane.write("{ done: true }", base: "null")
        XCTAssertEqual(written["kind"] as? String, "written")
        let text = try XCTUnwrap(written["text"] as? String)
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), text)
        XCTAssertEqual(text, "{\n  \"done\" : true\n}\n")

        // The agent writes it; the page, not yet told, writes from what it last saw.
        try "{\"done\": false, \"by\": \"agent\"}\n".write(
            to: data, atomically: true, encoding: .utf8)
        let stale = try await pane.write("{ done: true, note: 1 }", base: "window.__base")
        XCTAssertEqual(stale["kind"] as? String, "changed")
        XCTAssertEqual(stale["text"] as? String, "{\"done\": false, \"by\": \"agent\"}\n")
        XCTAssertEqual(
            try String(contentsOf: data, encoding: .utf8), "{\"done\": false, \"by\": \"agent\"}\n",
            "nothing written over the agent's version")
    }

    /// **The agent's write reaches the live page as data**, naming the live file, and the page's
    /// own write does not come back to it as an update.
    func testAnAgentsWriteIsOfferedToThePageNamingTheLiveFile() async throws {
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()
        _ = try await pane.write("{ done: true }", base: "null")

        // benchd reports the page's own write: nothing to offer.
        pane.model.fileChanged(data.path)
        XCTAssertEqual(pane.model.showing?.generation, 0, "the page's own write is not news")

        try "{\"done\": false}\n".write(to: data, atomically: true, encoding: .utf8)
        pane.model.fileChanged(data.path)
        let showing = try XCTUnwrap(pane.model.showing)
        XCTAssertEqual(showing.generation, 1)
        pane.render()

        let update = try await pane.poll("window.__updates[0]")
        XCTAssertEqual(update["file"] as? String, "tasks.data.json")
        XCTAssertEqual(update["artifact"] as? String, "tasks.html")
        let boot = try await pane.poll("window.__boot")
        XCTAssertEqual(boot["loads"] as? Int, 1, "applied as data: the page was not reloaded")
    }

    /// **Two changes offered at once name the artifact.** A reconnect's re-read finds both the
    /// page and its live file changed and bumps twice; a page told only "your data changed" would
    /// keep showing markup that is gone.
    func testAPageAndItsLiveFileChangedTogetherAreOfferedAsThePage() async throws {
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()

        try (Self.page + "<!-- rewritten -->").write(
            to: artifact, atomically: true, encoding: .utf8)
        try "{\"done\": false}\n".write(to: data, atomically: true, encoding: .utf8)
        pane.model.reread()
        XCTAssertEqual(pane.model.showing?.generation, 2)
        pane.render()

        let update = try await pane.poll("window.__updates[0]")
        XCTAssertEqual(update["file"] as? String, "tasks.html")
    }

    /// **Two data changes one render missed are still named as data**: the page takes them in
    /// place rather than being offered a reload.
    func testTwoLiveFileChangesInOneRenderAreOfferedAsTheLiveFile() async throws {
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()

        for done in ["false", "true"] {
            try "{\"done\": \(done)}\n".write(to: data, atomically: true, encoding: .utf8)
            pane.model.fileChanged(data.path)
        }
        XCTAssertEqual(pane.model.showing?.generation, 2)
        pane.render()

        let update = try await pane.poll("window.__updates[0]")
        XCTAssertEqual(update["file"] as? String, "tasks.data.json")
    }

    // MARK: - The artifact

    /// A page that writes through `window.__write`, keeps what it was answered, and takes updates.
    private static let page = """
        <!doctype html><html><body>tasks<script>
        window.__boot = { loads: (Number(sessionStorage.loads || 0) + 1) };
        sessionStorage.loads = window.__boot.loads;
        window.__base = null;
        window.__updates = [];
        window.helmCanvasUpdate = function (update) { window.__updates.push(update); return true; };
        window.__write = function (data, base) {
          window.__answer = null;
          window.webkit.messageHandlers.\(CanvasDataWrite.handlerName)
            .postMessage({ kind: "\(CanvasDataWrite.kind)", data: data, base: base, notify: false })
            .then(function (answer) { window.__base = answer.text; window.__answer = answer; },
                  function (error) { window.__answer = { error: String(error) }; });
        };
        window.webkit.messageHandlers.probe.postMessage("loaded");
        </script></body></html>
        """

    // MARK: - The pane that hosts it

    /// The real webview and the real model, wired as `HTMLCanvasWebView` wires them.
    @MainActor
    private final class Pane: NSObject, WKScriptMessageHandler {
        private let path: StandardizedPath
        private let coordinator: CanvasFileCoordinator
        private let webView: WKWebView
        let model = CanvasModel()
        private var loads = 0

        init(artifact: URL) throws {
            path = StandardizedPath(artifact.path)
            coordinator = CanvasFileCoordinator(
                host: CanvasAddress.host(for: path), onAnnotation: { _ in })
            webView = HTMLCanvasPage.makeWebView(
                for: path, coordinator: coordinator, files: DiskCanvasFiles())
            super.init()
            model.open(artifact)
            coordinator.onDataWrite = { [weak self] in
                self?.model.pageWroteData($0)
                    ?? .failure(CanvasFileFailure(reason: "the test is over"))
            }
            webView.configuration.userContentController.add(self, name: "probe")
        }

        /// What SwiftUI's `updateNSView` does with the model's current document.
        func render() {
            let showing = model.showing
            HTMLCanvasPage.load(
                webView, path: path, generation: showing?.generation ?? 0, theme: .dark,
                changes: showing?.changes ?? [:], coordinator: coordinator)
        }

        func firstLoad() async throws {
            render()
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if loads >= 1 { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("the page never loaded — this test's precondition, not its subject")
        }

        /// The page writes `data` from `base` (JavaScript expressions), and this answers what its
        /// promise resolved with.
        func write(_ data: String, base: String) async throws -> [String: Any] {
            _ = await ask("window.__write(\(data), \(base)); 'ok'")
            return try await poll("window.__answer")
        }

        /// A JavaScript value, once it is not null, as an object.
        func poll(_ expression: String) async throws -> [String: Any] {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                let json = await ask("JSON.stringify(\(expression) || null)")
                if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                    as? [String: Any]
                {
                    return object
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("\(expression) never arrived on the page")
            return [:]
        }

        /// Whether the artifact's own JavaScript sees one of helm's handlers, by direct property
        /// access from the page world.
        func visible(_ name: String) async -> Bool {
            await ask(
                """
                String(!!(window.webkit && window.webkit.messageHandlers
                  && window.webkit.messageHandlers.\(name)))
                """) == "true"
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
