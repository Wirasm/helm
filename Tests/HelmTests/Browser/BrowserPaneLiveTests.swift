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

    /// F3 (#548): on a retina pane the frames are retina — twice the page's CSS size — and a
    /// click through the surface lands on the CSS pixel under it, at 100% and zoomed. Red on a
    /// browser started without `--force-device-scale-factor=2`: Chrome screencasts at 1x
    /// whatever scale the pane emulates.
    func testFramesAreRetinaAndAClickLandsWhereItWasAimed() async throws {
        // In a window, so the click goes in as a real `NSEvent` through the surface's own
        // mapping. The window's display may be 1x; the pane is told 2x either way.
        let window = NSWindow(
            contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = surface
        surface.model = pane
        pane.viewportChanged(size: CGSize(width: 800, height: 500), scale: 2)

        let target = try await show(
            "<title>ready</title><body style='margin:0;height:100vh' onmousedown=\""
                + "document.title = 'at:' + event.clientX + ',' + event.clientY"
                + " + ' in:' + innerWidth\">")
        var frameWidth = 0
        try await eventually("a 2x frame (last \(frameWidth) px wide)") {
            frameWidth = (self.surface.layer?.contents as! CGImage?)?.width ?? 0
            return frameWidth == 1600
        }

        func click(atView point: CGPoint) {
            // The surface is flipped and fills the window; the window counts up from the bottom.
            let location = CGPoint(x: point.x, y: 500 - point.y)
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1)!
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 0)!
            surface.mouseDown(with: down)
            surface.mouseUp(with: up)
        }
        // Clicked until it lands, since the first frame may predate the pane's fit; the page
        // says how wide it was laid out, so a click mapped through a stale frame cannot pass.
        try await eventually("the click at 100% (\(pane.tabs.current?.title ?? ""))") {
            click(atView: CGPoint(x: 200, y: 100))
            try? await Task.sleep(for: .milliseconds(100))
            return self.pane.tabs.current?.title == "at:200,100 in:800"
        }

        // At 125% the page is 640×400 CSS pixels drawn over the same 800×500 points.
        pane.perform(.zoom(.increase))
        pane.perform(.zoom(.increase))
        XCTAssertEqual(pane.zoom[target], 1.25)
        try await eventually("the click at 125% (\(pane.tabs.current?.title ?? ""))") {
            click(atView: CGPoint(x: 200, y: 100))
            try? await Task.sleep(for: .milliseconds(100))
            return self.pane.tabs.current?.title == "at:160,80 in:640"
        }
        // Still 2x CSS pixels: Chrome draws at its forced scale, not the zoom-raised one the pane
        // emulates, so a zoomed page is 1280 px over 800 points. Sharper than before, not perfect.
        XCTAssertEqual((surface.layer?.contents as! CGImage?)?.width, 1280)
        pane.close(tab: target)
    }

    // MARK: - Links, the menu and the cursor (#610)

    /// The surface in a window, so clicks go in as real `NSEvent`s, with a frame on it.
    private func windowed() async throws -> NSWindow {
        let window = NSWindow(
            contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        surface.model = pane
        return window
    }

    /// The page's document is in and drawn. A gesture's listener armed in the blank document a
    /// new tab starts with would never hear the click that lands in the page after it.
    private func loaded() async throws {
        try await eventually("the page is loaded (\(pane.tabs.current?.title ?? ""))") {
            self.pane.tabs.current?.title == "ready" && self.surface.layer?.contents != nil
        }
    }

    private func click(
        _ window: NSWindow, _ down: NSEvent.EventType, _ up: NSEvent.EventType,
        _ flags: NSEvent.ModifierFlags
    ) {
        for type in [down, up] {
            let event = NSEvent.mouseEvent(
                with: type, location: CGPoint(x: 100, y: 400), modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == down ? 1 : 0)!
            switch type {
            case .leftMouseDown: surface.mouseDown(with: event)
            case .leftMouseUp: surface.mouseUp(with: event)
            case .rightMouseDown: surface.rightMouseDown(with: event)
            default: surface.rightMouseUp(with: event)
            }
        }
    }

    /// AC1: ⌘-click on a link opens it as the operator's tab, shown and not marked as an
    /// agent's — and only once: Chrome's own background tab is stopped by the listener.
    func testACommandClickedLinkOpensAsTheOperatorsTab() async throws {
        let window = try await windowed()
        defer { window.close() }
        let link = "http://127.0.0.1:9/helm-610-\(UUID().uuidString)"
        let page = try await show(
            "<title>ready</title><a href='\(link)' style='display:block;height:100vh'>go</a>")
        try await loaded()
        let before = pane.tabs.tabs.count
        click(window, .leftMouseDown, .leftMouseUp, .command)
        try await eventually("the link is the tab on show (\(pane.tabs.current?.url ?? ""))") {
            self.pane.tabs.current?.url == link
        }
        let opened = try XCTUnwrap(pane.tabs.showing)
        XCTAssertFalse(pane.tabs.fromOutside.contains(opened), "the operator's, not an agent's")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(pane.tabs.tabs.count, before + 1, "one tab: Chrome opened none of its own")
        pane.close(tab: opened)
        pane.close(tab: page)
    }

    /// AC2: a page that handles ⌘-click itself keeps it, and right-click on a page with its own
    /// menu shows none of ours.
    func testAPageThatClaimsTheGestureKeepsIt() async throws {
        let window = try await windowed()
        defer { window.close() }
        var menus = 0
        surface.presentMenu = { _, _, _ in menus += 1 }
        let page = try await show(
            "<title>ready</title><a href='http://127.0.0.1:9/x' style='display:block;height:100vh'"
                + " onclick=\"event.preventDefault(); document.title = 'page:' + event.metaKey\""
                + " oncontextmenu=\"event.preventDefault(); document.title = 'menu'\">x</a>")
        try await loaded()
        let before = pane.tabs.tabs.count
        click(window, .leftMouseDown, .leftMouseUp, .command)
        try await eventually("the page handled it (\(pane.tabs.current?.title ?? ""))") {
            self.pane.tabs.current?.title == "page:true"
        }
        click(window, .rightMouseDown, .rightMouseUp, [])
        try await eventually("the page drew its menu (\(pane.tabs.current?.title ?? ""))") {
            self.pane.tabs.current?.title == "menu"
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(pane.tabs.tabs.count, before, "no tab opened")
        XCTAssertEqual(menus, 0, "no native menu over the page's")
        pane.close(tab: page)
    }

    /// AC3: right-click on a link, on a page with no menu of its own, gets the native one.
    func testARightClickOnALinkGetsTheNativeMenu() async throws {
        let window = try await windowed()
        defer { window.close() }
        var shown: [String] = []
        surface.presentMenu = { menu, _, _ in shown = menu.items.map(\.title) }
        let page = try await show(
            "<title>ready</title><a href='http://127.0.0.1:9/menu'"
                + " style='display:block;height:100vh'>x</a>")
        try await loaded()
        click(window, .rightMouseDown, .rightMouseUp, [])
        try await eventually("the menu (\(shown))") {
            shown == ["Open Link in New Tab", "Copy Link"]
        }
        pane.close(tab: page)
    }

    /// AC4: the page says which cursor is under a point: a link's, text's, a field's, its CSS.
    func testThePageSaysWhichCursorIsUnderThePointer() async throws {
        let page = try await show(
            "<body style='margin:0;font:20px sans-serif'>"
                + "<a href='http://127.0.0.1:9/' style='display:block;height:40px'>link</a>"
                + "<p style='margin:0;height:40px'>plain text</p>"
                + "<input style='display:block;height:40px;width:200px'>"
                + "<div style='cursor:col-resize;height:40px'></div>")
        try await eventually("the link's cursor") {
            await self.pane.cursor(at: CGPoint(x: 10, y: 20)) == "pointer"
        }
        let text = await pane.cursor(at: CGPoint(x: 10, y: 50))
        let field = await pane.cursor(at: CGPoint(x: 10, y: 100))
        let resize = await pane.cursor(at: CGPoint(x: 10, y: 140))
        let empty = await pane.cursor(at: CGPoint(x: 700, y: 60))
        XCTAssertEqual([text, field, resize, empty], ["text", "text", "col-resize", "default"])
        pane.close(tab: page)
    }
}
