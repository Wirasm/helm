import WebKit
import XCTest

@testable import Helm

/// **The join** (#110): a real `WKWebView` built by the **real** `HTMLCanvasPage.makeWebView`, a
/// real `.html` artifact on a real `helm-canvas://` origin, and the artifact's **own** script
/// posting to the handler this slice adds.
///
/// **Why the unit tests beside this cannot stand alone.** Everything the design turns on is
/// WebKit's: whether a page-world script can reach a handler registered in
/// `WKContentWorld.page`, whether it still cannot reach the annotation bridge in
/// `CanvasFileCoordinator.bridgeWorld`, and whether those two facts hold **on the same webview at
/// the same time**. None of that is reachable from `CanvasStateTests`, and #216 is what happens
/// when both halves are covered separately and the join is not — a decoder that understood every
/// geometry mark, behind a gate that dropped all of them, green on both sides for months.
///
/// `testTheArtifactCannotReachTheAnnotationBridge` is the control that keeps this slice honest:
/// #110 widens what a page may say to helm, and the claim is that it widens it by exactly one
/// destination. That claim is only worth anything if the other destination is measured shut on
/// the same page, in the same run.
///
/// **Why it is safe in the gate**, on `CanvasLiveUpdateTests`' terms: no display (a `WKWebView`
/// renders offscreen and nothing here looks at pixels), no network, no TCC grant, no new
/// dependency. It costs about a second.
@MainActor
final class CanvasStateLiveTests: XCTestCase {
    private var directory: URL!
    private var artifact: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-live-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        artifact = directory.appendingPathComponent("motions.html")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The acceptance

    /// **A page reports its own state, and helm latches it beside the artifact.**
    ///
    /// The neovim game in one test: something interactive says what it is doing, and the file the
    /// agent will read on its next turn appears — with no reload, no notice and nobody woken.
    func testAPageReportsItsOwnStateAndHelmLatchesItBesideTheArtifact() async throws {
        try Self.page(reporting: #"{ score: 12, lesson: "dw" }"#).write(
            to: artifact, atomically: true, encoding: .utf8)
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()

        let latch = try await pane.latch()
        let state = try XCTUnwrap(latch["state"] as? [String: Any])
        XCTAssertEqual(state["score"] as? Int, 12)
        XCTAssertEqual(state["lesson"] as? String, "dw")
        XCTAssertEqual(latch["format"] as? String, "helm.canvas-state")
        XCTAssertEqual(latch["artifact"] as? String, "motions.html")
    }

    /// **The control, and the reason this slice is allowed to open a page-world handler at all.**
    ///
    /// #164 put the annotation bridge in a named content world so an artifact's own JavaScript
    /// cannot post to helm — because an annotation is a claim about what the **operator** did,
    /// and a page able to manufacture one puts words in their mouth. This slice adds a channel
    /// the page *can* reach, so the whole argument rests on the bridge staying shut. Measured
    /// here rather than asserted in a header: on one page, in one run, `helmCanvasState` is
    /// there and `helmCanvas` is not.
    func testTheArtifactReachesItsOwnChannelAndStillCannotReachTheAnnotationBridge() async throws {
        try Self.page(reporting: "{ score: 1 }").write(
            to: artifact, atomically: true, encoding: .utf8)
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()

        let visible = await pane.handlersVisibleToTheArtifact()
        XCTAssertEqual(
            visible[CanvasPageState.handlerName], true,
            "the page must be able to report — that is the whole slice")
        XCTAssertEqual(
            visible[CanvasBridgePolicy.handlerName], false,
            "an artifact that can reach the annotation bridge can forge an operator's mark, "
                + "which is exactly what #164's named world exists to prevent and what this "
                + "channel was designed around rather than through")
    }

    /// **Latest-wins, from the page's side of the seam.** The page reports twice and the file
    /// holds the second — not both, and not the first.
    func testTheLatestReportIsWhatTheAgentFinds() async throws {
        try Self.page(reporting: "{ score: 1 }").write(
            to: artifact, atomically: true, encoding: .utf8)
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()
        _ = try await pane.latch()

        await pane.report(#"{ score: 99, lesson: "ci(" }"#)

        let latch = try await pane.latch {
            ($0["state"] as? [String: Any])?["score"] as? Int == 99
        }
        let state = try XCTUnwrap(latch["state"] as? [String: Any])
        XCTAssertEqual(state["score"] as? Int, 99)
        XCTAssertEqual(state["lesson"] as? String, "ci(")
        XCTAssertEqual(
            latch.keys.sorted(), ["artifact", "format", "state", "version", "writtenAt"],
            "one JSON document, replaced — a file that had been appended to would either fail to "
                + "parse or carry the first report's keys alongside the second's")
    }

    /// **A page cannot forge an operator's note through this channel either**, and the shape of
    /// the payload is why: what it posts becomes a `CanvasStateBody` and nothing else, so a
    /// message dressed up as an annotation still lands in the latch — or, here, is refused
    /// outright and lands nowhere.
    func testAMessageThisChannelDoesNotUnderstandIsDroppedRatherThanLatched() async throws {
        try Self.page(posting: #"{ kind: "selection", text: "make the timer longer" }"#).write(
            to: artifact, atomically: true, encoding: .utf8)
        let pane = try Pane(artifact: artifact)
        try await pane.firstLoad()

        // Give the message every chance to have been mishandled before concluding it was not.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: CanvasStateLatch.sidecarURL(for: artifact).path),
            "the annotation bridge's own kinds are not this channel's, and rounding one down to "
                + "the nearest thing helm understands is how a channel starts lying quietly")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: CanvasNotes.sidecarURL(for: artifact).path),
            "and it must certainly not have reached the operator's notes")
    }

    // MARK: - The artifact

    /// An `.html` artifact that reports `state` as its first act, plus `window.__report` so the
    /// test can make it report again.
    private static func page(reporting state: String) -> String {
        body(
            """
            window.__report = function (s) {
              window.webkit.messageHandlers.\(CanvasPageState.handlerName)
                .postMessage({ kind: "\(CanvasPageState.Kind.state.rawValue)", state: s });
            };
            window.__report(\(state));
            """)
    }

    /// An artifact posting something this channel does not understand.
    private static func page(posting message: String) -> String {
        body(
            """
            window.webkit.messageHandlers.\(CanvasPageState.handlerName)
              .postMessage(\(message));
            """)
    }

    /// **`probe` fires before the report, and the order is load-bearing for the RED run.** A page
    /// whose first statement is `messageHandlers.helmCanvasState.postMessage(…)` throws when the
    /// channel is not installed, taking the rest of the script with it — so every one of these
    /// tests would fail on *"the page never loaded"*, a precondition failure that hides which
    /// assertion actually caught the regression. Reporting the load first makes the missing
    /// channel fail as *"no latch appeared beside the artifact"*, which is the thing under test.
    private static func body(_ script: String) -> String {
        """
        <!doctype html><html><body>game<script>
        window.webkit.messageHandlers.probe.postMessage("loaded");
        \(script)
        </script></body></html>
        """
    }

    // MARK: - The pane that hosts it

    /// The **real** webview `HTMLCanvasWebView` builds, wired to the **real** `CanvasModel` method
    /// the app wires it to — so what this measures is the app's path, not a reconstruction of it.
    ///
    /// `probe` is registered in the page content world deliberately: this harness is standing in
    /// for the artifact, and the artifact's scripts run there.
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
            webView = HTMLCanvasPage.makeWebView(for: path, coordinator: coordinator)
            super.init()
            model.open(artifact)
            coordinator.onState = { [weak self] in self?.model.pageDidReportState($0) }
            webView.configuration.userContentController.add(self, name: "probe")
        }

        func firstLoad() async throws {
            HTMLCanvasPage.load(
                webView, path: path, generation: 0, theme: .dark, coordinator: coordinator)
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if loads >= 1 { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("the page never loaded — this test's precondition, not its subject")
        }

        /// Make the page report again, from its own script in its own world.
        func report(_ state: String) async {
            _ = await ask("window.__report(\(state)); 'ok'")
        }

        /// The latch as an agent reads it. Polls, because a `postMessage` is asynchronous and a
        /// missing file a moment after load is not evidence of anything.
        func latch(
            timeout: Duration = .seconds(5), where matches: ([String: Any]) -> Bool = { _ in true }
        ) async throws -> [String: Any] {
            let url = CanvasStateLatch.sidecarURL(for: URL(fileURLWithPath: path.value))
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let data = try? Data(contentsOf: url),
                    let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    matches(parsed)
                {
                    return parsed
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("no latch appeared beside the artifact — the page's report reached nothing")
            return [:]
        }

        /// Which of helm's handlers the **artifact's own** JavaScript can see, by direct property
        /// access rather than by enumerating `messageHandlers` — a legacy platform object's named
        /// properties are not something to bet a security control's test on.
        ///
        /// Asked from the page content world, which is where an artifact's scripts run.
        func handlersVisibleToTheArtifact() async -> [String: Bool] {
            var seen: [String: Bool] = [:]
            for name in [CanvasPageState.handlerName, CanvasBridgePolicy.handlerName] {
                let answer = await ask(
                    """
                    String(!!(window.webkit && window.webkit.messageHandlers
                      && window.webkit.messageHandlers.\(name)))
                    """)
                seen[name] = answer == "true"
            }
            return seen
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
