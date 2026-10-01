import AppKit
import HelmWire
import XCTest

@testable import Helm

/// Opt-in, isolated benchd/browser only. Exercises the surface callbacks through CDP into
/// real DOM composition events, not a real keyboard layout or an IME candidate window.
@MainActor
final class BrowserTextInputLiveTests: XCTestCase {
    func testCompositionUpdatesCommitAndCancelInTextControlsAndEditableContent() async throws {
        guard let root = ProcessInfo.processInfo.environment["HELM_BROWSER_LIVE_BENCH_DIR"] else {
            throw XCTSkip("needs an isolated benchd and throwaway browser profile")
        }
        let endpoint = try BenchRoot.endpoint(environment: ["BENCH_DIR": root]).get()
        let pane = BrowserPaneModel(endpoint: endpoint)
        defer { pane.close() }
        let surface = BrowserSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        surface.model = pane
        pane.surface = surface
        pane.viewportChanged(size: surface.bounds.size, scale: 2)
        try await eventually { pane.status == .connected }
        for control in [
            "<input id=i>", "<textarea id=i></textarea>",
            "<div id=i contenteditable=true></div>",
        ] {
            let html = """
                <meta charset=utf-8><style>#i {margin:80px;width:300px;font:20px monospace}</style>
                \(control)<script>
                const events = [];
                for (const name of ['compositionstart','compositionupdate','compositionend'])
                  i.addEventListener(name, e => events.push(name+':'+e.data));
                setInterval(() => { document.title = JSON.stringify({
                  value:i.value ?? i.textContent, events}) }, 20);
                i.focus(); document.title = 'ready';
                </script>
                """
            pane.open(
                try XCTUnwrap(
                    URL(
                        string: "data:text/html,"
                            + html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!))
            )
            try await eventually { pane.tabs.current?.title.contains("\"value\":\"\"") == true }
            let target = try XCTUnwrap(pane.tabs.showing)
            defer { pane.close(tab: target) }
            let none = NSRange(location: NSNotFound, length: 0)
            surface.setMarkedText(
                "´", selectedRange: .init(location: 1, length: 0), replacementRange: none)
            try await eventually { pane.tabs.current?.title.contains("compositionstart") == true }
            let pageCaret = await pane.textCaretRect()
            let caret = try XCTUnwrap(pageCaret)
            XCTAssertGreaterThan(caret.minX, 70)
            XCTAssertGreaterThan(caret.height, 0)
            surface.insertText("é", replacementRange: none)
            try await eventually { pane.tabs.current?.title.contains("\"value\":\"é\"") == true }
            XCTAssertTrue(pane.tabs.current?.title.contains("compositionend:é") == true)
            surface.setMarkedText(
                "あ", selectedRange: .init(location: 1, length: 0), replacementRange: none)
            try await eventually {
                pane.tabs.current?.title.contains("compositionupdate:あ") == true
            }
            surface.setMarkedText(
                "", selectedRange: .init(location: 0, length: 0), replacementRange: none)
            try await eventually {
                pane.tabs.current?.title.contains("\"compositionend:\"") == true
                    && pane.tabs.current?.title.contains("\"value\":\"é\"") == true
            }
        }
    }

    private enum WaitFailure: Error { case timeout }

    private func eventually(_ done: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while await !done() {
            guard ContinuousClock.now < deadline else {
                XCTFail("browser input did not arrive")
                throw WaitFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
