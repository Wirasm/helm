import AppKit
import HelmWire
import XCTest

@testable import Helm

@MainActor
final class BrowserControlsLiveTests: BrowserControlLiveCase {
    func testSelectChoiceUsesTheOptionIndexAndEmitsPageEvents() async throws {
        try await show(
            """
            <select id=field><option value=same>First</option><option disabled>Disabled</option>
            <option value=same>Second</option></select>
            <script>window.events=[]; for (const type of ['input','change'])
              field.addEventListener(type,e=>events.push(e.type));</script>
            """)
        try await click("field")
        try await eventually("select choices are visible in the pane") {
            self.pane.pageInput.forms.current != nil
        }
        key("ArrowDown", code: "ArrowDown", vk: 40)
        key("Enter", code: "Enter", vk: 13)
        try await eventually("second duplicate-value option is selected") {
            try await self.read("field.selectedIndex === 2", as: Bool.self)
        }
        let events = try await read("events", as: [String].self)
        XCTAssertEqual(events, ["input", "change"])
        XCTAssertNil(pane.pageInput.forms.current)
    }

    func testCancelAndDisabledOptionsLeaveTheValueAlone() async throws {
        try await show(
            "<select id=field><option>First</option><option disabled>Second</option></select>")
        try await click("field")
        try await eventually("select picker is visible") {
            self.pane.pageInput.forms.current != nil
        }
        await pane.pageInput.forms.choose(index: 1)
        XCTAssertNotNil(pane.pageInput.forms.failure)
        key("Escape", code: "Escape", vk: 27)
        try await eventually("cancel closes the picker") {
            self.pane.pageInput.forms.current == nil
        }
        let selected = try await read("field.selectedIndex", as: Int.self)
        XCTAssertEqual(selected, 0)
    }

    func testDatePickerChecksRangeAndStepThenCommitsAndClears() async throws {
        try await show(
            """
            <input id=field type=date value=2026-10-02 min=2026-10-02 max=2026-10-12 step=2>
            <script>window.events=[]; for (const type of ['input','change'])
              field.addEventListener(type,e=>events.push(e.type));</script>
            """)
        try await click("field")
        try await eventually("calendar state is on the pane") {
            self.pane.pageInput.forms.current != nil
        }
        for date in ["2026-10-01", "2026-10-13", "2026-10-03"] {
            await pane.pageInput.forms.choose(date: date)
            XCTAssertNotNil(pane.pageInput.forms.failure, date)
            let value = try await read("field.value", as: String.self)
            XCTAssertEqual(value, "2026-10-02")
        }
        await pane.pageInput.forms.choose(date: "2026-10-04")
        XCTAssertNil(pane.pageInput.forms.current)
        let chosen = try await read("field.value", as: String.self)
        XCTAssertEqual(chosen, "2026-10-04")
        try await click("field")
        try await eventually("calendar reopens") { self.pane.pageInput.forms.current != nil }
        await pane.pageInput.forms.choose(date: "")
        let cleared = try await read("field.value", as: String.self)
        let events = try await read("events", as: [String].self)
        XCTAssertEqual(cleared, "")
        XCTAssertEqual(events, ["input", "change", "input", "change"])
    }

    private func pastePage(cancel: Bool = false, editable: Bool = false) -> String {
        let field = editable ? "<div id=field contenteditable></div>" : "<input id=field>"
        return field + """
            <script>
              window.events=[];
              document.addEventListener('paste', e => {
                window.pasted={trusted:e.isTrusted, cancelable:e.cancelable, text:e.clipboardData.getData('text/plain'),
                  html:e.clipboardData.getData('text/html'),
                  files:[...e.clipboardData.files].map(f=>({type:f.type,size:f.size}))};
                events.push('paste'); if (\(cancel)) e.preventDefault();
              });
              for (const type of ['beforeinput','input'])
                field.addEventListener(type,e=>events.push(e.type + ':' + e.inputType));
              field.focus();
            </script>
            """
    }

    func testTextPasteIsTrustedAndInsertsOnceWithPasteSemantics() async throws {
        try await show(pastePage())
        board.setString("päste ✓", forType: .string)
        surface.paste(nil)
        try await eventually("page receives paste and insertion") {
            try await self.read("!!window.pasted && field.value === 'päste ✓'", as: Bool.self)
        }
        let trusted = try await read("pasted.trusted", as: Bool.self)
        let events = try await read("events", as: [String].self)
        XCTAssertTrue(trusted)
        XCTAssertEqual(events, ["paste", "beforeinput:insertFromPaste", "input:insertFromPaste"])
    }

    func testCanceledRichImagePasteSuppliesFormatsWithoutInserting() async throws {
        try await show(pastePage(cancel: true))
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 8, bitsPerPixel: 32))
        bitmap.bitmapData?.initialize(repeating: 0, count: 16)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        board.setString("rich", forType: .string)
        board.setString("<b>rich</b>", forType: .html)
        board.setData(png, forType: .png)
        surface.paste(nil)
        try await eventually("page receives canceled paste") {
            try await self.read("!!window.pasted", as: Bool.self)
        }
        let formats = try await read(
            "pasted.trusted && pasted.text==='rich' && pasted.html.includes('<b>rich</b>')"
                + " && pasted.files.length===1 && pasted.files[0].type==='image/png'", as: Bool.self
        )
        let events = try await read("events", as: [String].self)
        let value = try await read("field.value", as: String.self)
        let received = try await read("JSON.stringify(pasted)", as: String.self)
        XCTAssertTrue(formats, received)
        XCTAssertEqual(events, ["paste"])
        XCTAssertEqual(value, "")
    }

    func testRichPasteKeepsHTMLInAnEditor() async throws {
        try await show(pastePage(editable: true))
        board.setString("rich", forType: .string)
        board.setString("<b>rich</b>", forType: .html)
        surface.paste(nil)
        try await eventually("editor receives rich HTML") {
            try await self.read(
                "!!window.pasted && field.innerHTML.includes('<b>rich</b>')", as: Bool.self)
        }
    }

    func testInsecurePageReceivesCancellablePasteAndFollowingTextStaysOrdered() async throws {
        try await show(pastePage(), secure: false)
        board.setString("first", forType: .string)
        surface.paste(nil)
        pane.insertText("second")
        try await eventually("insecure page gets paste before following text") {
            try await self.read("!!window.pasted && field.value==='firstsecond'", as: Bool.self)
        }
        let trusted = try await read("pasted.trusted", as: Bool.self)
        XCTAssertFalse(trusted, "the insecure-page fallback is a synthetic clipboard event")
    }

    func testInsecurePageCanCancelPaste() async throws {
        try await show(pastePage(cancel: true), secure: false)
        board.setString("canceled", forType: .string)
        surface.paste(nil)
        try await eventually("insecure handler receives paste") {
            try await self.read("!!window.pasted", as: Bool.self)
        }
        let canceled = try await read(
            "pasted.cancelable && field.value==='' && events.join(',')==='paste'", as: Bool.self)
        XCTAssertTrue(canceled)
    }

    func testCompositionWaitsForPasteThenCommitsInOrder() async throws {
        for secure in [true, false] {
            try await show(
                pastePage() + """
                    <script>window.timeline=[]; window.drained=false;
                    field.addEventListener('paste',()=>timeline.push('paste'));
                    field.addEventListener('compositionstart',()=>timeline.push('composition'));
                    document.addEventListener('keyup',e=>{if(e.key==='F8') drained=true});
                    </script>
                    """, secure: secure)
            board.setString("first", forType: .string)
            surface.paste(nil)
            surface.setMarkedText(
                "あ", selectedRange: .init(location: 1, length: 0),
                replacementRange: .init(location: NSNotFound, length: 0))
            surface.insertText("é", replacementRange: .init(location: NSNotFound, length: 0))
            pane.key(
                .init(
                    type: "keyUp", modifiers: 0, key: "F8", code: "F8", windowsVirtualKeyCode: 119))
            try await eventually("the queued composition commit is drained") {
                try await self.read("drained", as: Bool.self)
            }
            let timeline = try await read("timeline", as: [String].self)
            let value = try await read("field.value", as: String.self)
            XCTAssertEqual(timeline, ["paste", "composition"])
            XCTAssertEqual(value, "firsté")
        }
    }

    func testImageOnlyPasteDoesNotNeedAStringOnTheClipboard() async throws {
        try await show(pastePage(cancel: true))
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 8, bitsPerPixel: 32))
        bitmap.bitmapData?.initialize(repeating: 0, count: 16)
        // macOS screenshots commonly arrive as TIFF. The surface converts that to PNG.
        board.setData(try XCTUnwrap(bitmap.tiffRepresentation), forType: .tiff)
        surface.paste(nil)
        try await eventually("image-only handler receives a PNG file") {
            try await self.read(
                "!!window.pasted && pasted.files.length===1 && pasted.files[0].type==='image/png'",
                as: Bool.self)
        }
        let native = try await read("pasted.trusted && pasted.text==='';", as: Bool.self)
        XCTAssertTrue(native)
    }
}
