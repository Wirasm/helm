import AppKit
import XCTest

@testable import Helm

/// Opt-in isolated Chrome proof of clicking away from a preedit, then continuing typing.
@MainActor
final class BrowserCompositionClickLiveTests: BrowserControlLiveCase {
    func testClickAwayEndsCompositionBeforeTheNextKeyCanCommitItAgain() async throws {
        try await composeAndClick("b")
    }

    func testClickWithinTheFieldEndsCompositionBeforeTheNextKeyCanCommitItAgain() async throws {
        try await composeAndClick("i")
    }

    private func composeAndClick(_ target: String) async throws {
        try await show(
            "<input id=i style='margin:80px;font:20px monospace'><button id=b>elsewhere</button>"
                + "<script>let ended=0; i.addEventListener('compositionend', () => ended++);</script>"
        )
        try await click("i")
        let none = NSRange(location: NSNotFound, length: 0)
        surface.setMarkedText(
            "あ", selectedRange: .init(location: 1, length: 0), replacementRange: none)
        try await eventually("preedit visible") {
            try await self.read("i.value", as: String.self) == "あ"
        }
        let image = try XCTUnwrap(surface.layer?.contents) as! CGImage
        let page = try await read("[innerWidth, innerHeight]", as: [Double].self)
        let point = try await read(
            "(() => { const r=document.getElementById('\(target)').getBoundingClientRect();"
                + " return [r.x+r.width/2,r.y+r.height/2]; })()",
            as: [Double].self)
        let rect = BrowserGeometry.viewRect(
            CGRect(x: point[0], y: point[1], width: 1, height: 1), in: surface.bounds.size,
            image: CGSize(width: image.width, height: image.height),
            page: CGSize(width: page[0], height: page[1]))
        let window = NSWindow(
            contentRect: surface.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: surface.convert(rect.origin, to: nil),
                modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        surface.mouseDown(with: event)
        try await eventually("click reached the field or button and Chrome ended composition") {
            try await self.read(
                "document.activeElement.id === '\(target)' && ended === 1", as: Bool.self)
        }
        XCTAssertFalse(
            surface.hasMarkedText(), "Chrome committed on click; AppKit must not retain the preedit"
        )
        // The next ordinary key unmarks local preedit before typing (see BrowserTextInputTests).
        try await click("i")
        surface.unmarkText()
        pane.insertText("x")
        try await eventually("next text arrived") {
            try await self.read("i.value.endsWith('x')", as: Bool.self)
        }
        let value = try await read("i.value", as: String.self)
        XCTAssertEqual(value, "あx", "the preedit must be committed only once")
    }
}
