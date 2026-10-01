import AppKit
import XCTest

@testable import Helm

/// AppKit composition callbacks at the CDP seam, independent of pointer/clipboard tests.
@MainActor
final class BrowserTextInputTests: XCTestCase {
    private final class Recorder: BrowserInputSink {
        var keys: [BrowserPaneModel.KeyEvent] = []
        var inserted: [String] = []
        var compositions: [(String, NSRange)] = []
        func setComposition(_ text: String, selection: NSRange) {
            compositions.append((text, selection))
        }
        func mouse(_: BrowserPaneModel.MouseEvent) {}
        func key(_ params: BrowserPaneModel.KeyEvent) { keys.append(params) }
        func insertText(_ text: String) { inserted.append(text) }
        func paste(_: BrowserPaste) {}
        func textCaretRect() async -> CGRect? { CGRect(x: 40, y: 20, width: 1, height: 18) }
        func selectedText() async -> String? { nil }
        func viewportChanged(size _: CGSize, scale _: CGFloat) {}
        func gesture(_: BrowserGesture, dispatch: () -> Void) async -> BrowserPointerReport? {
            dispatch()
            return nil
        }
        func cursor(at _: CGPoint) async -> String? { nil }
        func open(_: URL) {}
        func perform(_: BrowserCommand) {}
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
            "あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        surface.unmarkText()
        XCTAssertEqual(recorder.inserted, ["あ"])
        XCTAssertFalse(surface.hasMarkedText())
        surface.setMarkedText(
            "´", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        surface.setMarkedText(
            "", selectedRange: .init(location: 0, length: 0), replacementRange: none)
        XCTAssertEqual(recorder.compositions.last?.0, "")
        XCTAssertEqual(recorder.inserted, ["あ"], "cancellation never inserts an accent")
    }

    func testDeadKeyCallbackCommitReplacesTheMarkedAccent() {
        let none = NSRange(location: NSNotFound, length: 0)
        surface.setMarkedText(
            "´", selectedRange: .init(location: 1, length: 0), replacementRange: none)
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
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "e",
            charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 0x0E)!
        surface.keyDown(with: event)
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
        while surface.firstRect(forCharacterRange: .init(location: 0, length: 1), actualRange: nil)
            != expected
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
}
