import AppKit
import XCTest

@testable import Helm

@MainActor
final class BrowserControlBoundaryLiveTests: BrowserControlLiveCase {
    func testSameOriginFrameAndClosedShadowControlsCanBeChosen() async throws {
        try await show(
            """
            <iframe id=frame srcdoc="<select id=field><option>First</option><option>Second</option></select>"></iframe>
            <div id=host></div><script>
              const shadow=host.attachShadow({mode:'closed'});
              shadow.innerHTML='<select><option>First</option><option>Second</option></select>';
              window.closedField=shadow.firstChild;
            </script>
            """)
        try await eventually("same-origin frame is loaded") {
            try await self.read("!!frame.contentDocument.getElementById('field')", as: Bool.self)
        }
        let point = try await read(
            """
            (() => { const outer=frame.getBoundingClientRect();
              const inner=frame.contentDocument.getElementById('field').getBoundingClientRect();
              return [outer.x+frame.clientLeft+inner.x+inner.width/2,
                outer.y+frame.clientTop+inner.y+inner.height/2]; })()
            """, as: [Double].self)
        for type in ["mousePressed", "mouseReleased"] {
            pane.mouse(.init(type: type, x: point[0], y: point[1], button: "left", clickCount: 1))
        }
        try await eventually("frame picker is visible") { self.pane.pageInput.forms.current != nil }
        await pane.pageInput.forms.choose(index: 1)
        let frameValue = try await read(
            "frame.contentDocument.getElementById('field').selectedIndex", as: Int.self)
        XCTAssertEqual(frameValue, 1)

        let shadowPoint = try await read(
            "(() => { const r=closedField.getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2]; })()",
            as: [Double].self)
        for type in ["mousePressed", "mouseReleased"] {
            pane.mouse(
                .init(
                    type: type, x: shadowPoint[0], y: shadowPoint[1], button: "left", clickCount: 1)
            )
        }
        try await eventually("shadow picker is visible") {
            self.pane.pageInput.forms.current != nil
        }
        await pane.pageInput.forms.choose(index: 1)
        let shadowValue = try await read("closedField.selectedIndex", as: Int.self)
        XCTAssertEqual(shadowValue, 1)
    }

    func testPageClickHandlersCanReplaceThePicker() async throws {
        try await show(
            """
            <select id=field><option>First</option><option>Second</option></select>
            <script>window.clicks=0; field.addEventListener('mousedown',e=>e.preventDefault());
              field.addEventListener('click',e=>{e.preventDefault();clicks++});</script>
            """)
        try await click("field")
        try await eventually("page click handler runs") {
            try await self.read("clicks === 1", as: Bool.self)
        }
        XCTAssertNil(pane.pageInput.forms.current)
        let selected = try await read("field.selectedIndex", as: Int.self)
        XCTAssertEqual(selected, 0)
    }

    func testListboxesAndOrdinaryClicksStillReachChrome() async throws {
        try await show(
            """
            <select id=field size=3><option>First</option><option>Second</option></select>
            <button id=button onclick='window.clicked=true'>Click</button>
            """)
        try await click("field")
        _ = try await read("field.selectedIndex=0; field.focus(); true", as: Bool.self)
        key("ArrowDown", code: "ArrowDown", vk: 40)
        try await eventually("listbox keyboard input reaches Chrome") {
            try await self.read("field.selectedIndex === 1", as: Bool.self)
        }
        XCTAssertNil(pane.pageInput.forms.current)
        try await click("button")
        try await eventually("ordinary button receives its click") {
            try await self.read("!!window.clicked", as: Bool.self)
        }
    }

    func testDetachedElementAndChangedOptionsCannotChangeAnotherField() async throws {
        try await show("<select id=field><option>First</option><option>Second</option></select>")
        try await click("field")
        try await eventually("picker is open") { self.pane.pageInput.forms.current != nil }
        _ = try await read("field.options[1].text='Replaced'; true", as: Bool.self)
        await pane.pageInput.forms.choose(index: 1)
        XCTAssertNotNil(pane.pageInput.forms.failure)
        let unchanged = try await read("field.selectedIndex", as: Int.self)
        XCTAssertEqual(unchanged, 0)
        _ = try await read(
            "field.outerHTML='<select id=field><option>New</option></select>'; true", as: Bool.self)
        await pane.pageInput.forms.choose(index: 1)
        let replacement = try await read("field.value", as: String.self)
        XCTAssertEqual(replacement, "New")
        pane.pageInput.forms.dismiss()
    }

    func testNavigationDismissesAnOpenPicker() async throws {
        try await show("<select id=field><option>First</option><option>Second</option></select>")
        try await click("field")
        try await eventually("picker is open") { self.pane.pageInput.forms.current != nil }
        pane.navigate(to: "about:blank")
        try await eventually("navigation drops old picker") {
            self.pane.tabs.current?.url == "about:blank" && self.pane.pageInput.forms.current == nil
        }
    }
}
