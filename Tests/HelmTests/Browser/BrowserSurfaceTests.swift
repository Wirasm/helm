import AppKit
import XCTest

@testable import Helm

/// The whole path from an AppKit event to the CDP event the browser receives, through
/// AppKit's own text input — no browser, no socket, a recorder where the model would be.
@MainActor
final class BrowserSurfaceTests: XCTestCase {
    private final class Recorder: BrowserInputSink {
        var keys: [BrowserPaneModel.KeyEvent] = []
        var mice: [BrowserPaneModel.MouseEvent] = []
        var inserted: [String] = []
        func mouse(_ params: BrowserPaneModel.MouseEvent) { mice.append(params) }
        func key(_ params: BrowserPaneModel.KeyEvent) { keys.append(params) }
        func insertText(_ text: String) { inserted.append(text) }
        func selectedText() async -> String? { nil }
        func viewportChanged(size _: CGSize, scale _: CGFloat) {}

        var gestures: [BrowserGesture] = []
        /// What the page answers a gesture with, as `BrowserPaneModel.gesture` would.
        var report: BrowserPointerReport?
        var cursorAnswer: String?
        var opened: [URL] = []
        var commands: [BrowserCommand] = []
        func gesture(
            _ gesture: BrowserGesture, dispatch: () -> Void
        ) async -> BrowserPointerReport? {
            gestures.append(gesture)
            dispatch()
            return report
        }
        func cursor(at _: CGPoint) async -> String? { cursorAnswer }
        func open(_ url: URL) { opened.append(url) }
        func perform(_ command: BrowserCommand) { commands.append(command) }
    }

    private var window: NSWindow!
    private var surface: BrowserSurfaceView!
    private var recorder: Recorder!

    override func setUp() async throws {
        recorder = Recorder()
        surface = BrowserSurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        surface.model = recorder
        surface.keyTable = { KeyBindings.all }
        window = NSWindow(
            contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        window.makeFirstResponder(surface)
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    private func press(
        _ keyCode: UInt16, _ characters: String, ignoring: String? = nil,
        _ flags: NSEvent.ModifierFlags = [], repeating: Bool = false
    ) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters, isARepeat: repeating,
            keyCode: keyCode)!
        surface.keyDown(with: event)
    }

    /// #545: with `nativeVirtualKeyCode` in the event, Chrome on macOS redispatches a key the
    /// page leaves unhandled back into the page forever, and the shared browser freezes. `b` is
    /// the key that did it (Mac key code 11; `a` is 0 and so looked safe), held or not.
    func testAKeyGoesOutWithoutANativeKeyCode() throws {
        press(0x0B, "b")
        press(0x0B, "b", repeating: true)
        XCTAssertEqual(recorder.keys.count, 2)
        for key in recorder.keys {
            let json = try JSONEncoder().encode(key)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
            XCTAssertEqual(fields["code"] as? String, "KeyB")
            XCTAssertNil(fields["nativeVirtualKeyCode"], "Chrome loops on it: #545")
        }
    }

    func testTypingAShiftedDigitSendsItsTextOnThePhysicalKey() throws {
        press(0x14, "#", ignoring: "3", .shift)
        let key = try XCTUnwrap(recorder.keys.first)
        XCTAssertEqual(key.type, "keyDown")
        XCTAssertEqual(key.text, "#")
        XCTAssertEqual(key.windowsVirtualKeyCode, 51, "the spike sent 35 — End")
        XCTAssertEqual(key.code, "Digit3")
        XCTAssertEqual(key.modifiers, BrowserModifiers.shift.rawValue)
    }

    func testEnterTypesACarriageReturnSoAFormSubmits() throws {
        press(0x24, "\r")
        let key = try XCTUnwrap(recorder.keys.first)
        XCTAssertEqual(key.type, "keyDown")
        XCTAssertEqual(key.text, "\r")
        XCTAssertEqual(key.key, "Enter")
        XCTAssertNil(key.commands, "no insertNewline command on top of the key's own newline")
    }

    func testBackspaceGoesOutAsTheEditingCommandAppKitBindsItTo() throws {
        press(0x33, "\u{7F}")
        let key = try XCTUnwrap(recorder.keys.first)
        XCTAssertEqual(key.type, "rawKeyDown")
        XCTAssertNil(key.text)
        XCTAssertEqual(key.windowsVirtualKeyCode, 8)
        XCTAssertEqual(key.commands, ["deleteBackward"])
    }

    func testACommandKeyNoMenuTookTypesNothing() throws {
        press(0x00, "a", .command)
        let key = try XCTUnwrap(recorder.keys.first)
        XCTAssertEqual(key.type, "rawKeyDown")
        XCTAssertNil(key.text, "⌘A is not the letter a")
        XCTAssertEqual(key.commands, ["selectAll"])
    }

    private func keyEquivalent(
        _ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags
    ) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        return window.contentView!.performKeyEquivalent(with: event)
    }

    /// #548: ⌘K, ⌘N, ⌘D and ⌘O are the page's in a browser pane. The key monitor leaves them
    /// alone there, and the view takes them before the main menu, whose items mirror helm's rows
    /// with their chords and would otherwise open the palette, a terminal, a split, a panel.
    func testAChordHelmBindsElsewhereGoesToThePageBeforeAnyMenu() throws {
        for (keyCode, letter) in [(UInt16(0x28), "k"), (0x2D, "n"), (0x02, "d"), (0x1F, "o")] {
            recorder.keys.removeAll()
            XCTAssertTrue(keyEquivalent(keyCode, letter, .command), "⌘\(letter) is the page's")
            let key = try XCTUnwrap(recorder.keys.first, "⌘\(letter) never reached the page")
            XCTAssertEqual(key.key, letter)
            XCTAssertEqual(key.modifiers, BrowserModifiers.meta.rawValue)
        }
    }

    /// The other side: a chord helm never binds (⌘Q) is the menu's, and one helm binds for the
    /// browser (⌘W, a browser key) is the key monitor's. Neither is taken here.
    func testEveryOtherChordGoesOnToTheMenu() {
        XCTAssertFalse(keyEquivalent(0x0C, "q", .command))
        XCTAssertFalse(keyEquivalent(0x0D, "w", .command))
        XCTAssertTrue(recorder.keys.isEmpty)
    }

    /// Only the surface holding the keyboard: AppKit offers a key equivalent to every view in
    /// the key window, and a pane the operator is not typing in has no claim to it.
    func testASurfaceWithoutTheKeyboardTakesNothing() {
        window.makeFirstResponder(nil)
        XCTAssertFalse(keyEquivalent(0x28, "k", .command))
        XCTAssertTrue(recorder.keys.isEmpty)
    }

    func testPasteInsertsTheClipboardAsText() {
        let board = NSPasteboard(name: .init("helm-browser-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        surface.pasteboard = board
        board.clearContents()
        board.setString("päste ✓", forType: .string)
        surface.paste(nil)
        XCTAssertEqual(recorder.inserted, ["päste ✓"])
    }

    func testAClickLandsOnThePagePointUnderIt() throws {
        // A 200×100 CSS page drawn at 2× into a 400×300 pane: aspect-fit leaves 50pt bands
        // above and below.
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        surface.show(BrowserFrame(image: image, pageSize: CGSize(width: 200, height: 100)))
        XCTAssertEqual(
            BrowserGeometry.pagePoint(
                CGPoint(x: 200, y: 150), in: surface.bounds.size,
                image: CGSize(width: 400, height: 200), page: CGSize(width: 200, height: 100)),
            CGPoint(x: 100, y: 50))
        XCTAssertNil(
            BrowserGeometry.pagePoint(
                CGPoint(x: 200, y: 20), in: surface.bounds.size,
                image: CGSize(width: 400, height: 200), page: CGSize(width: 200, height: 100)),
            "the band above the page is not the page")
    }

    // MARK: - Scrolling (#544)

    /// A wheel event at the middle of the pane, as the WindowServer would deliver it: a line
    /// event for a mouse wheel, a continuous pixel event for a trackpad.
    private func scroll(_ amount: Int32, precise: Bool) throws {
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        surface.show(BrowserFrame(image: image, pageSize: CGSize(width: 400, height: 300)))
        let cg = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1,
                wheel1: amount, wheel2: 0, wheel3: 0))
        if precise { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
        // CGEvent locations are global with a top-left origin; Cocoa's screen points are not.
        let middle = window.convertPoint(
            toScreen: surface.convert(NSPoint(x: 200, y: 150), to: nil))
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        cg.location = CGPoint(x: middle.x, y: top - middle.y)
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertEqual(event.hasPreciseScrollingDeltas, precise, "the event is the kind meant")
        surface.scrollWheel(with: event)
    }

    /// One notch of a mouse wheel is a line, not a pixel: it scrolls what one notch scrolls in
    /// Chrome on a Mac (40 px). It used to go out as 1 px (#544, F4).
    func testAMouseWheelNotchScrollsTheWayChromeDoes() throws {
        try scroll(-1, precise: false)
        let wheel = try XCTUnwrap(recorder.mice.last)
        XCTAssertEqual(wheel.type, "mouseWheel")
        XCTAssertEqual(wheel.deltaY, 40, "one notch down scrolls 40 px")
    }

    /// A trackpad already reports pixels, and must keep scrolling exactly that far.
    func testATrackpadScrollsTheExactPixels() throws {
        try scroll(-10, precise: true)
        let wheel = try XCTUnwrap(recorder.mice.last)
        XCTAssertEqual(wheel.deltaY, 10, "a precise delta passes through unscaled")
    }

    // MARK: - Links, the menu and the cursor (#610)

    /// A frame filling the 400×300 pane, so a pane point is the same page point.
    private func showPage() throws {
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        surface.show(BrowserFrame(image: image, pageSize: CGSize(width: 400, height: 300)))
    }

    private func mouse(
        _ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 100, y: 200), modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
    }

    /// A middle-button event: `NSEvent.mouseEvent` cannot carry a button number, a `CGEvent`
    /// can. Placed as the scroll test places its own (global, top-left origin).
    private func middle(_ type: CGEventType) throws -> NSEvent {
        let point = window.convertPoint(toScreen: NSPoint(x: 100, y: 200))
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let cg = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGPoint(x: point.x, y: top - point.y), mouseButton: .center))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// Lets the surface's gesture task run to its end.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private static let link = BrowserPointerReport(
        prevented: false, link: "https://example.com/x", claimed: true, selection: "",
        editable: false)

    /// AC1: ⌘-click on a link the listener claimed opens it as the operator's tab, and the page
    /// still gets the press and the release, in that order, though the release arrived while
    /// the press waited for the listener.
    func testACommandClickOnALinkOpensItAndStillReachesThePage() async throws {
        try showPage()
        recorder.report = Self.link
        surface.mouseDown(with: try mouse(.leftMouseDown, .command))
        surface.mouseUp(with: try mouse(.leftMouseUp, .command))
        XCTAssertTrue(recorder.mice.isEmpty, "the press waits for the listener")
        await settle()
        XCTAssertEqual(recorder.gestures, [.commandClick])
        XCTAssertEqual(recorder.opened, [URL(string: "https://example.com/x")!])
        XCTAssertEqual(recorder.mice.map(\.type), ["mousePressed", "mouseReleased"])
        XCTAssertEqual(recorder.mice.first?.modifiers, BrowserModifiers.meta.rawValue)
    }

    func testAMiddleClickIsSentAsTheMiddleButtonAndOpensTheLink() async throws {
        try showPage()
        recorder.report = Self.link
        let press = try middle(.otherMouseDown)
        XCTAssertEqual(press.buttonNumber, 2, "the event is a middle press")
        surface.otherMouseDown(with: press)
        surface.otherMouseUp(with: try middle(.otherMouseUp))
        await settle()
        XCTAssertEqual(recorder.gestures, [.middleClick])
        XCTAssertEqual(recorder.mice.map(\.button), ["middle", "middle"])
        XCTAssertEqual(recorder.mice.first?.buttons, 4)
        XCTAssertEqual(recorder.opened.count, 1)
    }

    /// AC2: a page that handled the click itself keeps it; nothing opens.
    func testALinkThePageClaimedIsNotOpened() async throws {
        try showPage()
        recorder.report = BrowserPointerReport(
            prevented: true, link: "https://example.com/x", claimed: false, selection: "",
            editable: false)
        surface.mouseDown(with: try mouse(.leftMouseDown, .command))
        await settle()
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    /// AC5, the control: a plain click is not a gesture and goes out at once.
    func testAPlainClickGoesOutAtOnceAndAsksNothing() throws {
        try showPage()
        surface.mouseDown(with: try mouse(.leftMouseDown))
        XCTAssertEqual(recorder.mice.map(\.type), ["mousePressed"])
        XCTAssertTrue(recorder.gestures.isEmpty)
    }

    /// AC3: right-click on a link shows the native menu with the link's items; on a page that
    /// drew its own menu, none.
    func testARightClickShowsTheMenuUnlessThePageDrewItsOwn() async throws {
        try showPage()
        var shown: [[String]] = []
        surface.presentMenu = { menu, _, _ in shown.append(menu.items.map(\.title)) }
        recorder.report = Self.link
        surface.rightMouseDown(with: try mouse(.rightMouseDown))
        await settle()
        XCTAssertEqual(recorder.gestures, [.contextMenu])
        XCTAssertEqual(shown, [["Open Link in New Tab", "Copy Link"]])
        XCTAssertTrue(recorder.opened.isEmpty, "the menu opens nothing by itself")

        recorder.report = BrowserPointerReport(
            prevented: true, link: nil, claimed: false, selection: "", editable: false)
        surface.rightMouseDown(with: try mouse(.rightMouseDown))
        await settle()
        XCTAssertEqual(shown.count, 1, "the page's own menu, not ours")
    }

    func testTheMenuOffersWhatFitsUnderThePointer() {
        func items(
            _ link: String?, _ selection: String, _ editable: Bool, paste: Bool = true
        ) -> [String] {
            BrowserContextMenu.items(
                for: .init(
                    prevented: false, link: link, claimed: false, selection: selection,
                    editable: editable),
                canPaste: paste
            ).map(\.title)
        }
        XCTAssertEqual(items(nil, "", false), ["Back", "Forward", "Reload"])
        XCTAssertEqual(items(nil, "fox", false), ["Copy"])
        XCTAssertEqual(items(nil, "", true), ["Paste"])
        XCTAssertEqual(items(nil, "", true, paste: false), ["Back", "Forward", "Reload"])
        XCTAssertEqual(items("mailto:a@b.c", "", false), ["Copy Link"], "only web links open")
    }

    func testTheMenusCopyItemsWriteTheClipboard() {
        let board = NSPasteboard(name: .init("helm-browser-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        surface.pasteboard = board
        surface.perform(.copyLink("https://example.com/x"))
        XCTAssertEqual(board.string(forType: .string), "https://example.com/x")
        surface.perform(.copy("the quick fox"))
        XCTAssertEqual(board.string(forType: .string), "the quick fox")
        surface.perform(.reload)
        XCTAssertEqual(recorder.commands, [.reload])
    }

    /// AC4: the pane takes the page's cursor.
    func testTheCursorFollowsThePage() async throws {
        try showPage()
        recorder.cursorAnswer = "pointer"
        surface.mouseMoved(with: try mouse(.mouseMoved))
        await settle()
        XCTAssertTrue(surface.pageCursor === NSCursor.pointingHand)
        recorder.cursorAnswer = "text"
        surface.mouseMoved(with: try mouse(.mouseMoved))
        await settle()
        XCTAssertTrue(surface.pageCursor === NSCursor.iBeam)
    }

    func testCSSCursorsMapToTheirMacCursors() {
        XCTAssertTrue(BrowserCursor.cursor(css: "pointer") === NSCursor.pointingHand)
        XCTAssertTrue(BrowserCursor.cursor(css: "col-resize") === NSCursor.resizeLeftRight)
        XCTAssertTrue(BrowserCursor.cursor(css: "grab") === NSCursor.openHand)
        XCTAssertTrue(BrowserCursor.cursor(css: "not-allowed") === NSCursor.operationNotAllowed)
        XCTAssertTrue(BrowserCursor.cursor(css: "default") === NSCursor.arrow)
        XCTAssertTrue(BrowserCursor.cursor(css: nil) === NSCursor.arrow, "no answer, no guess")
    }
}
