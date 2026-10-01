import AppKit
import XCTest

@testable import Helm

@MainActor
final class BrowserControlCorrectionsLiveTests: BrowserControlLiveCase {
    private func nested(_ container: String, select: Bool, cancel: Bool = true) -> String {
        """
        <script>
          window.events=[];
          function install(doc, root) {
            const e=doc.createElement('\(select ? "select" : "input")');
            if (\(select)) e.innerHTML='<option>First</option><option>Second</option>';
            root.appendChild(e); window.editor=e;
            e.addEventListener('paste',event=>{events.push('paste');
              if (\(cancel)) event.preventDefault();});
            e.focus();
          }
          function populate(doc) {
            if ('\(container)'==='open' || '\(container)'==='closed' || '\(container)'==='frame-shadow') {
              const host=doc.body.appendChild(doc.createElement('div'));
              install(doc,host.attachShadow({mode:'\(container == "open" ? "open" : "closed")'}));
            } else install(doc,doc.body);
          }
          addEventListener('load',()=>{
            if ('\(container)'==='frame' || '\(container)'==='frame-shadow') {
              const frame=document.createElement('iframe');
              frame.srcdoc='<html><body></body></html>';
              frame.onload=()=>populate(frame.contentDocument); document.body.appendChild(frame);
            } else populate(document);
          });
        </script>
        """
    }

    private func keyboardPicker(_ container: String) async throws {
        try await show(nested(container, select: true))
        try await eventually("nested select is focused") {
            try await self.read("!!window.editor", as: Bool.self)
        }
        key(" ", code: "Space", vk: 32)
        try await eventually("keyboard opens \(container) picker") {
            self.pane.pageInput.forms.current != nil
        }
        key("ArrowDown", code: "ArrowDown", vk: 40)
        key("Enter", code: "Enter", vk: 13)
        try await eventually("keyboard chooses nested second option") {
            try await self.read("editor.selectedIndex===1", as: Bool.self)
        }
    }

    func testKeyboardPickerInSameOriginFrame() async throws { try await keyboardPicker("frame") }
    func testKeyboardPickerInOpenShadow() async throws { try await keyboardPicker("open") }
    func testKeyboardPickerInClosedShadow() async throws { try await keyboardPicker("closed") }
    func testKeyboardPickerInShadowInsideFrame() async throws {
        try await keyboardPicker("frame-shadow")
    }

    private func fallbackPaste(_ container: String, cancel: Bool = true) async throws {
        try await show(nested(container, select: false, cancel: cancel), secure: false)
        try await eventually("nested editor is focused") {
            try await self.read("!!window.editor", as: Bool.self)
        }
        board.setString("blocked", forType: .string)
        surface.paste(nil)
        // A following input acts as a queue barrier without a timing sleep.
        pane.insertText("after")
        try await eventually("following text reaches nested editor") {
            try await self.read("editor.value.endsWith('after')", as: Bool.self)
        }
        let events = try await read("events", as: [String].self)
        let value = try await read("editor.value", as: String.self)
        XCTAssertEqual(events, ["paste"])
        XCTAssertEqual(value, cancel ? "after" : "blockedafter")
    }

    func testFallbackPasteCancellationInSameOriginFrame() async throws {
        try await fallbackPaste("frame")
    }
    func testFallbackPasteCancellationInClosedShadow() async throws {
        try await fallbackPaste("closed")
    }
    func testFallbackPasteCancellationInOpenShadow() async throws {
        try await fallbackPaste("open")
    }
    func testFallbackPasteDefaultInShadowInsideFrame() async throws {
        try await fallbackPaste("frame-shadow", cancel: false)
    }

    private func canceledLabel(_ kind: String) async throws {
        let field =
            kind == "select"
            ? "<select id=field><option>First</option></select>"
            : "<input id=field type=date>"
        try await show(
            "<label for=field onclick='event.preventDefault();window.clicked=true'>"
                + "<span id=label>Choose</span></label>" + field)
        try await click("label")
        try await eventually("original label receives click") {
            try await self.read("!!window.clicked", as: Bool.self)
        }
        XCTAssertNil(pane.pageInput.forms.current)
    }

    func testSelectLabelCanCancelActivation() async throws { try await canceledLabel("select") }
    func testDateLabelCanCancelActivation() async throws { try await canceledLabel("date") }

    func testNewTabAcceptsInputWhileOldPickerActivationWaitsForAlert() async throws {
        try await show("<select id=field onclick=\"alert('Wait')\"><option>First</option></select>")
        let old = try XCTUnwrap(pane.tabs.showing)
        let oldObserver = try XCTUnwrap(observing)
        try await observer.call("Page.enable", session: oldObserver)
        try await click("field")
        try await eventually("picker handler opened an alert") { self.pane.dialogs[old] != nil }
        defer { observer.send("Page.handleJavaScriptDialog", Accept(), session: oldObserver) }
        try await show("<input id=field><script>field.focus()</script>")
        pane.insertText("new-tab")
        try await eventually("new tab is responsive with old alert still open") {
            try await self.read("field.value==='new-tab'", as: Bool.self)
        }
        XCTAssertNotNil(pane.dialogs[old])
        observer.send("Page.handleJavaScriptDialog", Accept(), session: oldObserver)
        try await eventually("old operation unwound") { self.pane.dialogs[old] == nil }
        key(" ", code: "Space", vk: 32)
        pane.insertText("after")
        try await eventually("old operation did not steal or stop new input") {
            try await self.read("field.value==='new-tabafter'", as: Bool.self)
        }
        XCTAssertNil(pane.pageInput.forms.current)
    }

    private struct Accept: Encodable { var accept = true }
}
