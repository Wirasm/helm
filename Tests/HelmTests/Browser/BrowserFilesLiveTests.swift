import AppKit
import Foundation
import HelmWire
import XCTest

@testable import Helm

/// Find in page, file upload and downloads (#549) against a real benchd and a real browser.
///
/// **Skipped unless a harness sets it up**, as `BrowserPaneLiveTests` is: a benchd on a throwaway
/// root with its browser started, and either `HELM_BROWSER_LIVE_BENCH_DIR=<root>` (one machine:
/// benchd's unix socket) or `HELM_BROWSER_LIVE_BENCH_URL=tcp://<host>:<port>` (benchd started with
/// `BENCH_LISTEN`, so the pane takes the route a helm on another machine takes). Every test here
/// runs on both routes; what differs is how a file crosses, which is the point.
@MainActor
final class BrowserFilesLiveTests: XCTestCase {
    private var endpoint: BenchEndpoint!
    private var pane: BrowserPaneModel!
    private var surface: BrowserSurfaceView!
    private var scratch: URL!

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let url = environment["HELM_BROWSER_LIVE_BENCH_URL"] {
            endpoint = try BenchRoot.endpoint(environment: ["BENCH_URL": url]).get()
        } else if let root = environment["HELM_BROWSER_LIVE_BENCH_DIR"] {
            endpoint = try BenchRoot.endpoint(environment: ["BENCH_DIR": root]).get()
        } else {
            throw XCTSkip("needs a benchd with a started browser (see the header)")
        }
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-files-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        pane = BrowserPaneModel(endpoint: endpoint)
        surface = BrowserSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        pane.surface = surface
        pane.viewportChanged(size: CGSize(width: 800, height: 500), scale: 2)
        try await eventually("the pane connects") { self.pane.status == .connected }
    }

    override func tearDown() async throws {
        pane?.close()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
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

    private var title: String { pane.tabs.current?.title ?? "" }

    /// Opens `html` as a tab of its own, waits until the pane shows it and a frame of it is
    /// drawn — a frame newer than the last tab's, so input then reaches this page.
    private func show(_ html: String) async throws -> String {
        let marker = UUID().uuidString
        let before = surface.layer?.contents as AnyObject?
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
        try await eventually("a frame of it is on the pane") {
            let now = self.surface.layer?.contents as AnyObject?
            return now != nil && now !== before
        }
        return try XCTUnwrap(target)
    }

    /// The operator's click, as the surface sends it.
    private func click(_ x: Double, _ y: Double) {
        for type in ["mousePressed", "mouseReleased"] {
            pane.mouse(.init(type: type, x: x, y: y, button: "left", clickCount: 1))
        }
    }

    // MARK: - Find

    /// ⌘F's search: the next match is selected, again finds the one after, backwards the one
    /// before, and a word that is not there says so.
    func testFindSelectsEachMatchInTurnAndSaysWhenThereIsNone() async throws {
        let target = try await show(
            "<title>none</title><p><span id=one>alpha</span> beta <span id=two>alpha</span></p>"
                + "<script>document.onselectionchange = () => { const s = getSelection();"
                + " document.title = s.rangeCount ? 'sel:' + s.anchorNode.parentElement.id"
                + " + ':' + s : 'none' }</script>")
        let first = await pane.find("alpha", backwards: false, fromTop: true)
        XCTAssertEqual(first, true)
        try await eventually("the first match (\(title))") { self.title == "sel:one:alpha" }
        _ = await pane.find("alpha", backwards: false, fromTop: false)
        try await eventually("the next match (\(title))") { self.title == "sel:two:alpha" }
        _ = await pane.find("alpha", backwards: true, fromTop: false)
        try await eventually("back to the first (\(title))") { self.title == "sel:one:alpha" }
        let missing = await pane.find("omega", backwards: false, fromTop: true)
        XCTAssertEqual(missing, false)
        pane.close(tab: target)
    }

    // MARK: - Upload

    private let filePage =
        "<title>empty</title><input id=f type=file multiple"
        + " style='position:absolute;left:0;top:0;width:300px;height:80px'>"
        + "<script>f.onchange = () => { document.title = 'files:'"
        + " + [...f.files].map(x => x.name + ':' + x.size).join(',') }</script>"

    /// F7: the operator clicks a file input, chooses a file, and the page has it — by name and
    /// size — through Chrome's own file path. Over TCP the file crosses with `browser/upload`.
    func testAFileTheOperatorChoosesReachesThePage() async throws {
        let file = scratch.appendingPathComponent("upload.txt")
        try Data("upload-me\n".utf8).write(to: file)
        var asked: [Bool] = []
        pane.uploads.ask = { multiple, chosen in
            asked.append(multiple)
            chosen([file])
        }
        let target = try await show(filePage)
        click(20, 20)
        try await eventually("the page has the file (\(title))") {
            self.title == "files:upload.txt:10"
        }
        XCTAssertEqual(asked, [true], "one panel, allowing several, as the input does")
        if case .tcp = endpoint {
            // The route a helm on another machine takes: the path the page got is benchd's copy.
            guard case let .paths(paths) = BrowserFileChooser.paths(for: [file], endpoint: endpoint)
            else { return XCTFail("benchd refused the upload") }
            XCTAssertNotEqual(paths, [file.path])
            XCTAssertTrue(paths[0].contains("/browser/uploads/"), paths[0])
        }
        pane.close(tab: target)
    }

    /// Appear, don't seize: a file input an agent clicks on the tab the operator is looking at
    /// opens no panel in front of him. His own click on the same input then does.
    func testAnInputSomeoneElseClicksOpensNoPanel() async throws {
        var asked = 0
        pane.uploads.ask = { _, chosen in
            asked += 1
            chosen([])
        }
        let target = try await show(filePage)
        let agent = CDPConnection(endpoint: endpoint)
        agent.open()
        defer { agent.close() }
        let attached = try await agent.call(
            "Target.attachToTarget", AttachArgs(targetId: target, flatten: true),
            returning: AttachedSession.self)
        for type in ["mousePressed", "mouseReleased"] {
            try await agent.call(
                "Input.dispatchMouseEvent",
                MouseArgs(type: type, x: 20, y: 20, button: "left", clickCount: 1),
                session: attached.sessionId)
        }
        // Long enough for Chrome's report to reach the pane: the window only elapses, so a slow
        // machine makes this more certain, not less.
        try await Task.sleep(for: .seconds(2) + BrowserUploads.window)
        XCTAssertEqual(asked, 0, "an agent's click asked the operator for a file")
        click(20, 20)
        try await eventually("the operator's own click asks him") { asked == 1 }
        pane.close(tab: target)
    }

    // MARK: - Downloads

    /// F8: a download the page starts is listed, finishes with its path on benchd's machine, and
    /// reaches the Mac with its bytes — in place on one machine, copied over TCP.
    func testADownloadIsListedAndReachesTheMac() async throws {
        let name = "helm-live-\(UUID().uuidString).txt"
        pane.downloads.macFolder = scratch
        let target = try await show(
            "<title>dl</title><a id=a download='\(name)' href='data:text/plain,hello-live'"
                + " style='position:absolute;left:0;top:0;width:300px;height:80px'>get</a>")
        click(20, 20)
        try await eventually("the download is listed as finished (\(pane.downloads.items))") {
            self.pane.downloads.items.first { $0.name == name }?.state == .completed
        }
        let item = try XCTUnwrap(pane.downloads.items.first { $0.name == name })
        let landed = try XCTUnwrap(item.path)
        addTeardownBlock {
            // Where Chrome put it on benchd's machine: this test's own file, by its unique name.
            if (landed as NSString).lastPathComponent == name {
                try? FileManager.default.removeItem(atPath: landed)
            }
        }
        let onMac = try await pane.downloads.onMac(item.id).get()
        XCTAssertEqual(try Data(contentsOf: onMac), Data("hello-live".utf8))
        if case .tcp = endpoint {
            XCTAssertEqual(onMac.deletingLastPathComponent().path, scratch.path)
        } else {
            XCTAssertEqual(onMac.path, landed, "one machine opens the file where it is")
        }
        pane.close(tab: target)
    }
}

private struct AttachArgs: Encodable {
    let targetId: String
    let flatten: Bool
}

private struct AttachedSession: Decodable { let sessionId: String }

private struct MouseArgs: Encodable {
    let type: String
    let x: Double
    let y: Double
    let button: String
    let clickCount: Int
}
