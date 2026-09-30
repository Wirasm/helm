import AppKit
import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The browser pane against a real benchd and a real browser: what only Chrome can answer.
///
/// **Skipped unless a harness sets it up**, because the Swift gate needs no benchd or browser:
/// run a benchd on a throwaway root (`BENCH_DIR=<tmp> benchd`), start its browser (`BENCH_DIR=<tmp>
/// bench browser start`, a throwaway profile under that root), and run this with
/// `HELM_BROWSER_LIVE_BENCH_DIR=<tmp>`.
@MainActor
final class BrowserPaneLiveTests: XCTestCase {
    private var endpoint: BenchEndpoint!
    private var pane: BrowserPaneModel!
    /// Held here: the pane holds its surface weakly, as the view owns it in the app.
    private var surface: BrowserSurfaceView!

    override func setUp() async throws {
        guard let root = ProcessInfo.processInfo.environment["HELM_BROWSER_LIVE_BENCH_DIR"] else {
            throw XCTSkip("needs a benchd with a started browser (see the header)")
        }
        endpoint = try BenchRoot.endpoint(environment: ["BENCH_DIR": root]).get()
        pane = BrowserPaneModel(endpoint: endpoint)
        surface = BrowserSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        pane.surface = surface
        pane.viewportChanged(size: CGSize(width: 800, height: 500), scale: 2)
        try await eventually("the pane connects") { self.pane.status == .connected }
    }

    override func tearDown() async throws {
        pane?.close()
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

    /// Opens `html` as a tab of its own and waits until the pane shows it. Returns its target.
    private func show(_ html: String) async throws -> String {
        let marker = UUID().uuidString
        pane.open(
            try XCTUnwrap(
                URL(
                    string: "data:text/html,"
                        + ("<!-- \(marker) -->" + html).addingPercentEncoding(
                            withAllowedCharacters: .urlQueryAllowed)!)))
        var target: String?
        try await eventually("the page is the tab on show") {
            target = self.pane.tabs.current.flatMap {
                $0.url.contains(marker) ? $0.targetId : nil
            }
            return target != nil
        }
        return try XCTUnwrap(target)
    }

    /// F2 (#544): a `prompt` stops the page until somebody answers it, and only the session
    /// Chrome told can. The pane shows it, keeps it answerable across a tab switch, and the
    /// operator's answer reaches the page.
    func testAPromptShowsInThePaneAndItsAnswerReachesThePage() async throws {
        let target = try await show(
            "<title>asking</title><script>setTimeout(() => "
                + "{ document.title = 'said:' + prompt('Name?', 'helm') }, 300)</script>")
        try await eventually("the prompt is on the pane (\(pane.dialogs))") {
            self.pane.dialogs[target]?.kind == .prompt
        }
        XCTAssertEqual(pane.dialogs[target]?.message, "Name?")
        XCTAssertEqual(pane.dialogs[target]?.defaultPrompt, "helm")

        // Away and back: the session that can answer must survive the switch.
        pane.newTab()
        try await eventually("another tab is on show") { self.pane.tabs.showing != target }
        XCTAssertNotNil(pane.dialogs[target], "the dialog waits, badged, in the tab it is in")
        let other = try XCTUnwrap(pane.tabs.showing)
        pane.show(tab: target)
        try await eventually("the asking tab is back") { self.pane.tabs.showing == target }

        pane.answer(accept: true, text: "operator")
        try await eventually("the dialog is gone") { self.pane.dialogs[target] == nil }
        try await eventually("the page got the answer (\(pane.tabs.current?.title ?? ""))") {
            self.pane.tabs.current?.title == "said:operator"
        }
        pane.close(tab: target)
        pane.close(tab: other)
    }

    /// Input sent to a page stopped under a dialog is not lost: Chrome queues it and delivers it
    /// once the dialog is answered (measured). So the pane sends none while one is up, and what
    /// the operator typed at the stopped page never lands in it afterwards.
    func testInputUnderADialogNeverReachesThePageAfterwards() async throws {
        let target = try await show(
            "<title>typing</title><input id=i><script>setTimeout(() => { i.focus(); "
                + "alert('Stop'); setTimeout(() => { document.title = 'field:' + i.value }, 500) "
                + "}, 300)</script>")
        try await eventually("the alert is on the pane") { self.pane.dialogs[target] != nil }
        pane.insertText("typed-under-the-dialog")
        // ⌘C asks for the selection; under a dialog that would wait for the answer and then
        // overwrite whatever the operator copied meanwhile.
        let copied = await pane.selectedText()
        XCTAssertNil(copied, "no selection is read from a stopped page")
        for type in ["mousePressed", "mouseReleased"] {
            pane.mouse(.init(type: type, x: 20, y: 20, button: "left", clickCount: 1))
        }
        pane.answer(accept: true)
        try await eventually("the field is read back (\(pane.tabs.current?.title ?? ""))") {
            self.pane.tabs.current?.title.hasPrefix("field:") == true
        }
        XCTAssertEqual(pane.tabs.current?.title, "field:")
        pane.close(tab: target)
    }

    /// A page that asks before it is left: its `beforeunload` is a dialog like the others, and
    /// Leave lets the navigation go on.
    func testLeavingAPageThatAsksFirstWaitsForTheOperator() async throws {
        let target = try await show(
            "<title>unsaved</title><body style='height:100vh' onclick=\"location.href="
                + "'about:blank'\"><script>addEventListener('beforeunload',"
                + " e => { e.preventDefault(); e.returnValue = '' })</script>")
        // A click is the user activation Chrome wants before it will ask, and the navigation.
        try await eventually("a frame is on the pane") { self.surface.layer?.contents != nil }
        for type in ["mousePressed", "mouseReleased"] {
            pane.mouse(
                .init(type: type, x: 100, y: 100, button: "left", buttons: 0, clickCount: 1))
        }
        try await eventually("the pane asks (\(pane.dialogs))") {
            self.pane.dialogs[target]?.kind == .beforeunload
        }
        pane.answer(accept: true)
        // Chrome refuses a page's own navigation to a data: URL, so it leaves for a blank one.
        try await eventually("the page was left (\(pane.tabs.current?.url ?? ""))") {
            self.pane.tabs.current?.url == "about:blank"
        }
        pane.close(tab: target)
    }

    /// F12 (#544): ⌘+ zooms the page as Chrome does — it lays out narrower, at a higher
    /// `devicePixelRatio` — and ⌘0 puts it back.
    func testZoomReflowsThePageAndResetPutsItBack() async throws {
        let target = try await show(
            "<title>zoom</title><script>setInterval(() => "
                + "{ document.title = innerWidth + 'x' + devicePixelRatio }, 50)</script>")
        try await eventually("laid out at the pane's size (\(pane.tabs.current?.title ?? ""))") {
            self.pane.tabs.current?.title == "800x2"
        }
        pane.perform(.zoom(.increase))
        pane.perform(.zoom(.increase))
        XCTAssertEqual(pane.zoom[target], 1.25)
        try await eventually("zoomed to 125% (\(pane.tabs.current?.title ?? ""))") {
            self.pane.tabs.current?.title == "640x2.5"
        }
        pane.perform(.zoom(.reset))
        XCTAssertNil(pane.zoom[target])
        try await eventually("back at 100% (\(pane.tabs.current?.title ?? ""))") {
            self.pane.tabs.current?.title == "800x2"
        }
        pane.close(tab: target)
    }
}
