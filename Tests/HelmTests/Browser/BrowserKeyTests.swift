import XCTest

@testable import Helm

/// The names a key goes out under. The spike's viewer sent `charCodeAt` as the key code, so a
/// typed `#` arrived as End and 14 of 200 characters were lost; these pin the physical-key rule.
final class BrowserKeyTests: XCTestCase {
    func testAShiftedDigitKeepsItsDigitKeysCodeNotItsCharactersCode() {
        // ⇧3 on a US layout types '#', whose character code 0x23 is VK_END.
        let key = BrowserKey(macKeyCode: 0x14, charactersIgnoringModifiers: "3", text: "#")
        XCTAssertEqual(key.windowsVirtualKeyCode, 51, "the 3 key, never 35 (End)")
        XCTAssertEqual(key.code, "Digit3")
        XCTAssertEqual(key.key, "#", "the DOM key of a printable key is what it typed")
    }

    func testEveryCharacterTheSpikeLostMapsToAPrintableKeyNotANavigationKey() {
        // '$' Home, '%' ArrowLeft, '&' ArrowUp, ''' ArrowRight, '(' ArrowDown, '.' Delete — the
        // keys whose character codes collide with navigation VKs.
        let navigation: Set<Int> = [33, 34, 35, 36, 37, 38, 39, 40, 45, 46]
        let presses: [(UInt16, String)] = [
            (0x15, "$"), (0x17, "%"), (0x1A, "&"), (0x27, "'"), (0x19, "("), (0x2F, "."),
        ]
        for (code, typed) in presses {
            let key = BrowserKey(macKeyCode: code, charactersIgnoringModifiers: nil, text: typed)
            XCTAssertFalse(
                navigation.contains(key.windowsVirtualKeyCode),
                "\(typed) went out as navigation key \(key.windowsVirtualKeyCode)")
        }
    }

    func testNamedKeysCarryTheirDomNameWhateverAppKitReportsAsCharacters() {
        // AppKit reports ← as U+F702; that must never reach the page as a key or as text.
        let left = BrowserKey(macKeyCode: 0x7B, charactersIgnoringModifiers: "\u{F702}", text: nil)
        XCTAssertEqual(left.key, "ArrowLeft")
        XCTAssertEqual(left.windowsVirtualKeyCode, 37)
        let enter = BrowserKey(macKeyCode: 0x24, charactersIgnoringModifiers: "\r", text: nil)
        XCTAssertEqual(enter.key, "Enter")
        XCTAssertEqual(enter.windowsVirtualKeyCode, 13)
        let f5 = BrowserKey(macKeyCode: 0x60, charactersIgnoringModifiers: "\u{F708}", text: nil)
        XCTAssertEqual(f5.key, "F5")
        XCTAssertEqual(f5.windowsVirtualKeyCode, 116)
        XCTAssertNil(BrowserKey.printable("\u{F702}"))
        XCTAssertNil(BrowserKey.printable("\u{1B}"))
    }

    func testACommandKeyIsNamedByItsUnmodifiedCharacter() {
        let key = BrowserKey(macKeyCode: 0x00, charactersIgnoringModifiers: "a", text: nil)
        XCTAssertEqual(key.key, "a")
        XCTAssertEqual(key.code, "KeyA")
        XCTAssertEqual(key.windowsVirtualKeyCode, 65)
    }

    func testEditingSelectorsBecomeChromeCommandsExceptInsertionsAndNoop() {
        XCTAssertEqual(
            BrowserEditingCommand.name(forSelector: "deleteWordBackward:"), "deleteWordBackward")
        XCTAssertEqual(
            BrowserEditingCommand.name(forSelector: "moveToEndOfLine:"), "moveToEndOfLine")
        XCTAssertNil(
            BrowserEditingCommand.name(forSelector: "insertNewline:"),
            "the Enter key event inserts the newline; a command too would insert two")
        XCTAssertNil(BrowserEditingCommand.name(forSelector: "insertTab:"))
        XCTAssertNil(BrowserEditingCommand.name(forSelector: "noop:"))
    }

    func testTheAddressFieldAddsASchemeOnlyWhereNoneWasTyped() {
        XCTAssertEqual(BrowserAddress.url(from: "example.com"), "https://example.com")
        XCTAssertEqual(BrowserAddress.url(from: " http://a.test/x "), "http://a.test/x")
        XCTAssertEqual(BrowserAddress.url(from: "localhost:3000/app"), "http://localhost:3000/app")
        XCTAssertEqual(BrowserAddress.url(from: "about:blank"), "about:blank")
        XCTAssertNil(BrowserAddress.url(from: "two words"), "not a search box")
    }
}
