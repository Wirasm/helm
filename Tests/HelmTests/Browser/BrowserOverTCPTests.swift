import AppKit
import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The browser pane against a real benchd reached only over TCP, running a real browser this
/// process has no way to reach but through benchd (M5c, #459): the pane connects, shows frames
/// of the page, and what it types reaches the page.
///
/// **Skipped unless a harness sets it up**, because the Swift gate needs no benchd or browser: a
/// benchd with `BENCH_LISTEN` and a started browser (`bench browser start`, a throwaway profile
/// under its own root), and this test run with an empty `BENCH_DIR` and benchd's folder denied
/// (`sandbox-exec`). `HELM_REMOTE_BENCH_URL` names benchd. With `HELM_REMOTE_MEASURE=1` it also
/// prints the screencast's frame rate and the input round trip through the relay, as one
/// `MEASURE {…}` line.
@MainActor
final class BrowserOverTCPTests: XCTestCase {
    private var endpoint: BenchEndpoint!

    override func setUpWithError() throws {
        guard let url = ProcessInfo.processInfo.environment["HELM_REMOTE_BENCH_URL"] else {
            throw XCTSkip("needs a benchd over TCP with a browser (see the header)")
        }
        endpoint = try BenchRoot.endpoint(environment: ["BENCH_URL": url]).get()
    }

    private func eventually(
        _ what: @autoclosure () -> String, within seconds: Int = 20, _ done: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while await !done() {
            guard ContinuousClock.now < deadline else { return XCTFail("never: \(what())") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private struct Evaluated: Decodable {
        struct Remote: Decodable { let value: String? }
        let result: Remote
    }

    private struct Targets: Decodable { let targetInfos: [BrowserTab] }
    private struct Attached: Decodable { let sessionId: String }

    /// A second view onto the same browser, to read what the pane did to the page.
    private func pageValue(_ expression: String, url: String) async throws -> String? {
        let reader = CDPConnection(endpoint: endpoint)
        reader.open()
        defer { reader.close() }
        let targets = try await reader.call("Target.getTargets", returning: Targets.self)
        guard let tab = targets.targetInfos.first(where: { $0.url == url }) else { return nil }
        let attached = try await reader.call(
            "Target.attachToTarget", Attach(targetId: tab.targetId, flatten: true),
            returning: Attached.self)
        let value = try await reader.call(
            "Runtime.evaluate", Evaluate(expression: expression, returnByValue: true),
            session: attached.sessionId, returning: Evaluated.self)
        return value.result.value
    }

    func testThePaneShowsAndTypesIntoTheSharedBrowserThroughBenchdAlone() async throws {
        let pane = BrowserPaneModel(endpoint: endpoint)
        defer { pane.close() }
        let surface = BrowserSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        pane.surface = surface
        pane.viewportChanged(size: CGSize(width: 800, height: 500), scale: 2)

        try await eventually("the pane connects") { pane.status == .connected }
        pane.open(
            try XCTUnwrap(
                URL(string: Self.dataURL("<title>over-tcp</title><input id=i autofocus>"))))
        var url: String?
        try await eventually("the page is the tab on show (\(pane.tabs))") {
            url = pane.tabs.tabs.first { $0.targetId == pane.tabs.showing }?.url
            guard let url, url.hasPrefix("data:") else { return false }
            return (try? await pageValue("document.title", url: url)) == "over-tcp"
        }
        try await eventually("a frame of it reaches the pane") { surface.layer?.contents != nil }

        pane.insertText("typed through benchd")
        let page = try XCTUnwrap(url)
        try await eventually("the text reaches the page") {
            (try? await pageValue("document.getElementById('i').value", url: page))
                == "typed through benchd"
        }
    }

    /// Frames a second and the input round trip through the relay, printed for the evidence.
    func testMeasureTheRelay() async throws {
        guard ProcessInfo.processInfo.environment["HELM_REMOTE_MEASURE"] == "1" else {
            throw XCTSkip("HELM_REMOTE_MEASURE=1 runs the measurement")
        }
        let cdp = CDPConnection(endpoint: endpoint)
        cdp.open()
        defer { cdp.close() }
        let (target, session) = try await openMovingPage(cdp)

        var frames = 0
        var bytes = 0
        cdp.onEvent = { event in
            guard event.method == "Page.screencastFrame",
                let frame = event.params(ScreencastFrame.self)
            else { return }
            frames += 1
            bytes += frame.data.utf8.count
            cdp.send("Page.screencastFrameAck", Ack(sessionId: frame.sessionId), session: session)
        }
        try await cdp.call(
            "Page.startScreencast",
            Screencast(
                format: "jpeg", quality: 85, maxWidth: 2560, maxHeight: 1600, everyNthFrame: 1),
            session: session)
        try await Task.sleep(for: .seconds(2))
        frames = 0
        bytes = 0
        let window = 10.0
        try await Task.sleep(for: .seconds(window))
        let fps = Double(frames) / window
        let perFrame = frames > 0 ? bytes / frames : 0
        cdp.send("Page.stopScreencast", session: session)

        let keys = try await keyRoundTrips(cdp, session: session)
        let line: [String: Any] = [
            "url": ProcessInfo.processInfo.environment["HELM_REMOTE_BENCH_URL"] ?? "",
            "fps": (fps * 10).rounded() / 10,
            "frame_kb_base64": perFrame / 1024,
            "key_p50_ms": (keys[keys.count / 2] * 100).rounded() / 100,
            "key_p99_ms": (keys[keys.count * 99 / 100] * 100).rounded() / 100,
        ]
        let json = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        print("MEASURE " + String(decoding: json, as: UTF8.self))
        try await cdp.call("Target.closeTarget", Close(targetId: target))
    }

    /// A page of text that moves every frame, the way a scrolling page does, so the screencast
    /// has a new frame to send each time and each one is the size a text page makes. Returns its
    /// target and the session attached to it.
    private func openMovingPage(_ cdp: CDPConnection) async throws -> (String, String) {
        let page = Self.dataURL(
            "<body style='margin:0'><canvas id=c width=1280 height=800></canvas><script>"
                + "const x=c.getContext('2d');let n=0;const w='the quick brown fox jumps over the l"
                + "azy dog 0123456789 ';(function f(){x.fillStyle='#fff';x.fillRect(0,0,1280,800);x"
                + ".fillStyle='#222';x.font='13px sans-serif';for(let y=0;y<50;y++)x.fillText(w.rep"
                + "eat(8).slice((n+y)%50),4,16*y+14);n++;requestAnimationFrame(f)})()"
                + "</script>")
        struct Created: Decodable { let targetId: String }
        let created = try await cdp.call(
            "Target.createTarget", CreateTarget(url: page), returning: Created.self)
        let session = try await cdp.call(
            "Target.attachToTarget", Attach(targetId: created.targetId, flatten: true),
            returning: Attached.self
        ).sessionId
        try await cdp.call("Page.enable", session: session)
        cdp.send("Page.bringToFront", session: session)
        try await cdp.call(
            "Emulation.setDeviceMetricsOverride",
            Metrics(width: 1280, height: 800, deviceScaleFactor: 2, mobile: false),
            session: session)

        return (created.targetId, session)
    }

    /// Sorted round trips of a typed key in ms, which Chrome answers once the renderer handled it.
    private func keyRoundTrips(_ cdp: CDPConnection, session: String) async throws -> [Double] {
        var keys: [Double] = []
        for _ in 0..<200 {
            let start = ContinuousClock.now
            try await cdp.call(
                "Input.dispatchKeyEvent", Key(type: "char", text: "a"), session: session)
            let took = ContinuousClock.now - start
            keys.append(
                Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1e3)
        }
        return keys.sorted()
    }

    private static func dataURL(_ html: String) -> String {
        "data:text/html," + html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    }

    private struct Attach: Encodable {
        let targetId: String
        let flatten: Bool
    }
    private struct Evaluate: Encodable {
        let expression: String
        let returnByValue: Bool
    }
    private struct CreateTarget: Encodable { let url: String }
    private struct Close: Encodable { let targetId: String }
    private struct Metrics: Encodable {
        let width: Int
        let height: Int
        let deviceScaleFactor: Double
        let mobile: Bool
    }
    private struct Screencast: Encodable {
        let format: String
        let quality: Int
        let maxWidth: Int
        let maxHeight: Int
        let everyNthFrame: Int
    }
    private struct Ack: Encodable { let sessionId: Int }
    private struct Key: Encodable {
        let type: String
        let text: String
    }
}
