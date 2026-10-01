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
        var compositions: [(String, NSRange)] = []
        func setComposition(_ text: String, selection: NSRange) {
            compositions.append((text, selection))
        }
        func mouse(_ params: BrowserPaneModel.MouseEvent) { mice.append(params) }
        func key(_ params: BrowserPaneModel.KeyEvent) { keys.append(params) }
        func insertText(_ text: String) { inserted.append(text) }
        func textCaretRect() async -> CGRect? { CGRect(x: 40, y: 20, width: 1, height: 18) }
        func selectedText() async -> String? { nil }
        func viewportChanged(size _: CGSize, scale _: CGFloat) {}
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

    func testMarkedTextReachesThePageWithUTF16Selection() {
        let selection = NSRange(location: 2, length: 1)
        surface.setMarkedText(
            "😀あ", selectedRange: selection,
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(recorder.compositions.last?.0, "😀あ")
        XCTAssertEqual(recorder.compositions.last?.1, selection)
        XCTAssertEqual(surface.selectedRange(), selection)
        XCTAssertEqual(surface.markedRange(), NSRange(location: 0, length: 3))
    }

    func testEmptyMarkedTextCancelsAndUnmarkCommits() {
        let none = NSRange(location: NSNotFound, length: 0)
        surface.setMarkedText(
            "あ", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: none)
        surface.unmarkText()
        XCTAssertEqual(recorder.inserted, ["あ"])
        XCTAssertFalse(surface.hasMarkedText())
        surface.setMarkedText(
            "´", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: none)
        surface.setMarkedText(
            "", selectedRange: .init(location: 0, length: 0),
            replacementRange: none)
        XCTAssertEqual(recorder.compositions.last?.0, "")
        XCTAssertEqual(recorder.inserted, ["あ"], "cancellation never inserts an accent")
    }

    func testDeadKeyCallbackCommitReplacesTheMarkedAccent() {
        let none = NSRange(location: NSNotFound, length: 0)
        surface.setMarkedText(
            "´", selectedRange: .init(location: 1, length: 0),
            replacementRange: none)
        surface.insertText("é", replacementRange: none)
        XCTAssertEqual(recorder.inserted, ["é"])
        XCTAssertFalse(surface.hasMarkedText())
        XCTAssertTrue(recorder.keys.isEmpty)
    }

    func testAppKitUnmarksBeforeAnUnrelatedKeyAndThatKeyStillTypes() {
        surface.setMarkedText(
            "´", selectedRange: .init(location: 1, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0))
        // Manually setting the client's marked text does not start AppKit's own IME.
        // On the next ordinary key, AppKit unmarks it first. Preserve that commit and
        // still send the unrelated key, rather than mistaking this for a real dead key.
        press(0x0E, "e")
        XCTAssertEqual(recorder.inserted, ["´"])
        XCTAssertEqual(recorder.keys.map(\.text), ["e"])
        XCTAssertFalse(surface.hasMarkedText())
    }

    func testCandidateRectFollowsTheCaretThroughAspectFit() async throws {
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        surface.show(BrowserFrame(image: image, pageSize: CGSize(width: 200, height: 100)))
        surface.setMarkedText(
            "あ", selectedRange: .init(location: 1, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0))
        let expected = window.convertToScreen(
            surface.convert(CGRect(x: 80, y: 90, width: 2, height: 36), to: nil))
        let deadline = ContinuousClock.now + .seconds(2)
        while surface.firstRect(
            forCharacterRange: .init(location: 0, length: 1), actualRange: nil) != expected
        {
            guard ContinuousClock.now < deadline else { return XCTFail("caret never positioned") }
            await Task.yield()
        }
    }

    func testCompositionWireUsesUTF16AndOmitsDocumentReplacementOffsets() throws {
        let data = try JSONEncoder().encode(
            BrowserComposition(text: "😀あ", selection: .init(location: 2, length: 1)))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fields["selectionStart"] as? Int, 2)
        XCTAssertEqual(fields["selectionEnd"] as? Int, 3)
        XCTAssertNil(fields["replacementStart"])
        XCTAssertNil(fields["replacementEnd"])
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
}
