import AppKit
import XCTest

@testable import Helm

@MainActor
final class BrowserCaretLiveTests: BrowserControlLiveCase {
    private func caretAfterPaste(_ editor: String) async throws {
        for secure in [true, false] {
            try await show(
                """
                <style>#field {margin:70px;width:400px;height:180px;
                  font:20px monospace;line-height:30px;white-space:pre-wrap}</style>
                \(editor)
                <script>window.drained=false; field.focus();
                  document.addEventListener('keyup',e=>{if(e.key==='F8') drained=true});
                </script>
                """, secure: secure)
            board.setString("first\nsecond\nthird", forType: .string)
            surface.paste(nil)
            surface.setMarkedText(
                "あ", selectedRange: .init(location: 1, length: 0),
                replacementRange: .init(location: NSNotFound, length: 0))
            let requested = await pane.textCaretRect()
            pane.key(
                .init(
                    type: "keyUp", modifiers: 0, key: "F8", code: "F8",
                    windowsVirtualKeyCode: 119))
            try await eventually("paste and composition drain before comparing the caret") {
                try await self.read("drained", as: Bool.self)
            }
            let actual = await pane.textCaretRect()
            XCTAssertEqual(requested, actual, "dependent caret read must observe queued input")
            XCTAssertGreaterThan(try XCTUnwrap(requested).height, 0)
            let value = try await read("field.value ?? field.textContent", as: String.self)
            XCTAssertTrue(value.contains("third") && value.hasSuffix("あ"), value)
        }
    }

    func testInputCaretWaitsForPasteAndComposition() async throws {
        try await caretAfterPaste("<input id=field>")
    }
    func testTextareaCaretWaitsForMultilinePasteAndComposition() async throws {
        try await caretAfterPaste("<textarea id=field></textarea>")
    }
    func testEditableCaretWaitsForMultilinePasteAndComposition() async throws {
        try await caretAfterPaste("<div id=field contenteditable=true></div>")
    }

    func testResetDiscardsTheCaretWaitingForAnOldInputGeneration() async throws {
        try await show(
            """
            <textarea id=field></textarea><script>field.focus(); window.pending=false;
            navigator.clipboard.write=()=>new Promise((resolve,reject)=>{
              window.release=()=>{reject(new Error('fixture refusal')); return true}; pending=true;
            });</script>
            """)
        board.setString("old", forType: .string)
        surface.paste(nil)
        var started = false
        let request = Task {
            started = true; return await pane.textCaretRect()
        }
        try await eventually("old caret request waits with the pending clipboard write") {
            try await self.read("pending", as: Bool.self) && started
        }
        pane.pageInput.reset()
        let fresh = await pane.textCaretRect()
        XCTAssertNotNil(fresh, "a fresh generation must not wait on the old drain")
        _ = try await read("release()", as: Bool.self)
        let stale = await request.value
        XCTAssertNil(stale, "a reset generation must not publish its old caret")
    }
}
