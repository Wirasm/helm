import AppKit
import HelmWire
import XCTest

@testable import Helm

/// Opt-in real Chrome proof, with BrowserPaneLiveTests' isolated bench/profile contract.
/// Clipboard fixtures use a named board; headless Chrome's clipboard is in memory.
@MainActor
class BrowserControlLiveCase: XCTestCase {
    var pane: BrowserPaneModel!
    var surface: BrowserSurfaceView!
    var observer: CDPConnection!
    var observing: String!
    var board: NSPasteboard!
    var scratch: URL!

    override func setUp() async throws {
        guard let root = ProcessInfo.processInfo.environment["HELM_BROWSER_LIVE_BENCH_DIR"] else {
            throw XCTSkip("needs an isolated benchd/browser (BrowserPaneLiveTests)")
        }
        let endpoint = try BenchRoot.endpoint(environment: ["BENCH_DIR": root]).get()
        pane = BrowserPaneModel(endpoint: endpoint)
        surface = BrowserSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        surface.model = pane
        pane.surface = surface
        pane.viewportChanged(size: surface.bounds.size, scale: 2)
        observer = CDPConnection(endpoint: endpoint)
        observer.open()
        board = NSPasteboard(name: .init("helm-controls-\(UUID())"))
        surface.pasteboard = board
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helm-controls-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try await eventually("pane connects") { self.pane.status == .connected }
    }

    override func tearDown() async throws {
        pane?.close()
        observer?.close()
        board?.releaseGlobally()
        if let scratch { try FileManager.default.removeItem(at: scratch) }
    }

    func eventually(_ why: String, _ done: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try await !done() {
            if ContinuousClock.now >= deadline {
                XCTFail("never: \(why)")
                throw WaitFailure()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private struct WaitFailure: Error {}
    private struct Attach: Encodable { let targetId: String; var flatten = true }
    private struct Attached: Decodable { let sessionId: String }
    private struct Eval: Encodable { let expression: String; var returnByValue = true }
    private struct Reply<T: Decodable>: Decodable {
        struct Remote: Decodable { let value: T }
        let result: Remote
    }

    func read<T: Decodable>(_ expression: String, as _: T.Type = T.self) async throws -> T {
        try await observer.call(
            "Runtime.evaluate", Eval(expression: expression), session: observing,
            returning: Reply<T>.self
        ).result.value
    }

    func show(_ html: String, secure: Bool = true) async throws {
        let url: URL
        if secure {
            url = scratch.appendingPathComponent("\(UUID()).html")
            try html.write(to: url, atomically: true, encoding: .utf8)
        } else {
            url = try XCTUnwrap(
                URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString()))
        }
        let old = surface.layer?.contents as AnyObject?
        pane.open(url)
        try await eventually("fixture shown and a new frame arrived") {
            let now = self.surface.layer?.contents as AnyObject?
            return self.pane.tabs.current?.url == url.absoluteString && now != nil && now !== old
        }
        let attached = try await observer.call(
            "Target.attachToTarget", Attach(targetId: try XCTUnwrap(pane.tabs.showing)),
            returning: Attached.self)
        observing = attached.sessionId
        try await eventually("fixture loaded") {
            try await self.read("document.readyState === 'complete'", as: Bool.self)
        }
    }

    func click(_ id: String) async throws {
        let point = try await read(
            "(() => { const r=document.getElementById('\(id)').getBoundingClientRect();"
                + " return [r.x+r.width/2, r.y+r.height/2]; })()", as: [Double].self)
        for type in ["mousePressed", "mouseReleased"] {
            pane.mouse(.init(type: type, x: point[0], y: point[1], button: "left", clickCount: 1))
        }
    }

    func key(_ key: String, code: String, vk: Int) {
        pane.key(
            .init(type: "rawKeyDown", modifiers: 0, key: key, code: code, windowsVirtualKeyCode: vk)
        )
        pane.key(
            .init(type: "keyUp", modifiers: 0, key: key, code: code, windowsVirtualKeyCode: vk))
    }

}
