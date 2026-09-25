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
    }

    private var window: NSWindow!
    private var surface: BrowserSurfaceView!
    private var recorder: Recorder!

    override func setUp() async throws {
        recorder = Recorder()
        surface = BrowserSurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        surface.model = recorder
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
        _ flags: NSEvent.ModifierFlags = []
    ) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false,
            keyCode: keyCode)!
        surface.keyDown(with: event)
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
}
