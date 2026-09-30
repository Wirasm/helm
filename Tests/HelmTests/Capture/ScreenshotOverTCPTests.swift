import AppKit
import Foundation
import HelmWire
import XCTest

@testable import Helm

/// helm answering `bench get screenshot` for an agent on benchd's machine, when this process
/// reaches benchd only over TCP and cannot write the agent's folder (M5c, #459).
///
/// **Skipped unless a harness sets it up.** The harness runs this test (sandboxed away from
/// benchd's folder, with an empty `BENCH_DIR`) and, while it follows benchd, runs `bench get
/// screenshot --out <benchd's folder>/shot.png` on benchd's side. This test only answers: it
/// follows benchd over `HELM_REMOTE_BENCH_URL` with the app's own `HelmAsks` and a window of its
/// own, for `HELM_REMOTE_ANSWER_FOR` seconds. The harness then checks the file on benchd's side.
/// Written against APIs the tree before M5c also has, so the red run is this same file.
@MainActor
final class ScreenshotOverTCPTests: XCTestCase {
    func testAnswerAsksForAWhile() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HELM_REMOTE_BENCH_URL"],
            let seconds = env["HELM_REMOTE_ANSWER_FOR"].flatMap(Int.init)
        else { throw XCTSkip("needs a benchd over TCP and a harness asking (see the header)") }
        let endpoint = try BenchRoot.endpoint(environment: ["BENCH_URL": url]).get()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "helm — over-tcp"
        let view = NSView(frame: window.contentLayoutRect)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemTeal.cgColor
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }

        let client = BenchClient(endpoint: endpoint)
        let asks = HelmAsks.answering(
            through: client,
            capturer: AppWindowCapturer(
                windows: { [window] }, keyWindow: { nil }, terminals: { [] }))
        client.onEvent = { asks.receive($0) }
        client.start()
        defer { client.stop() }
        try await Task.sleep(for: .seconds(seconds))
    }
}
