import XCTest

@testable import Helm

@MainActor
final class BrowserOOPIFLifecycleLiveTests: BrowserOOPIFLiveCase {
    func testUnrelatedSiblingNavigationPreservesMainAndNestedPickers() async throws {
        for level in [Level.main, .middle, .leaf] {
            try await preservePicker(at: level, navigation: true)
        }
    }

    func testUnrelatedSiblingRemovalPreservesMainAndNestedPickers() async throws {
        for level in [Level.main, .middle, .leaf] {
            try await preservePicker(at: level, navigation: false)
        }
    }

    func testSameOriginOwningDocumentAndAncestorNavigationDismissPickers() async throws {
        for ancestor in [false, true] {
            try await invalidateOwnedPicker(ancestor: ancestor, navigation: true)
        }
    }

    func testSameOriginOwningDocumentAndAncestorRemovalDismissPickers() async throws {
        for ancestor in [false, true] {
            try await invalidateOwnedPicker(ancestor: ancestor, navigation: false)
        }
    }

    private func preservePicker(at level: Level, navigation: Bool) async throws {
        let installed: Bool = try await readFrame(
            "window.sibling=document.createElement('iframe'); sibling.id='sibling';"
                + "sibling.style='position:absolute;top:1000px'; sibling.srcdoc='<p id=ready>Initial</p>';"
                + "document.body.append(sibling); true", at: level)
        XCTAssertTrue(installed)
        try await eventually("same-origin sibling loaded in \(level)") {
            try await self.readFrame(
                "!!sibling.contentDocument?.getElementById('ready')", at: level)
        }
        let captured: Level = level == .main ? .main : .leaf
        let reset: Bool = try await readFrame(
            "document.querySelector('#select').selectedIndex=0; events=[]; true", at: captured)
        XCTAssertTrue(reset)
        try await keyboardOpen("document.querySelector('#select')", at: captured)
        let pick = try XCTUnwrap(pane.pageInput.forms.current?.id)
        let mutation =
            navigation
            ? "sibling.srcdoc='<p id=ready>Replacement</p>'; true"
            : "sibling.remove(); true"
        try await mutateFrame(
            "sibling", at: level, method: navigation ? "Page.frameNavigated" : "Page.frameDetached",
            mutation: mutation)
        XCTAssertEqual(
            pane.pageInput.forms.current?.id, pick,
            "unrelated \(level) activity keeps the captured picker")
        await pane.pageInput.forms.choose(index: 2)
        let selected: Int = try await readFrame(
            "document.querySelector('#select').selectedIndex", at: captured)
        let events: [String] = try await readFrame("events", at: captured)
        XCTAssertEqual(selected, 2)
        XCTAssertEqual(events, ["select:input", "select:change"])
        XCTAssertNil(pane.pageInput.forms.current)
    }

    private func keyboardOpen(_ expression: String, at level: Level = .leaf) async throws {
        let focused: Bool = try await readFrame("\(expression).focus(); true", at: level)
        XCTAssertTrue(focused)
        key(" ", code: "Space", vk: 32)
        try await eventually("focused same-origin control opens a picker") {
            self.pane.pageInput.forms.current != nil
        }
    }

    private let localHTML = """
        <select id=field><option>First</option><option>Second</option></select>
        <script>window.events=[]; for(const type of ['input','change'])
        field.addEventListener(type,e=>events.push(e.type));</script>
        """

    private var ancestorHTML: String {
        let content = localHTML.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return "<iframe id=owned srcdoc=\"\(content)\"></iframe>"
    }

    private func installOwnedFrames() async throws {
        let installed: Bool = try await readFrame(
            "window.ancestor=document.createElement('iframe'); ancestor.id='ancestor';"
                + "ancestor.style='position:absolute;top:1000px'; ancestor.srcdoc=\(quoted(ancestorHTML));"
                + "document.body.append(ancestor); true")
        XCTAssertTrue(installed)
        try await eventually("same-origin ancestor loaded") {
            try await self.readFrame("!!ancestor.contentDocument?.getElementById('owned')")
        }
        let assigned: Bool = try await readFrame(
            "window.owned=ancestor.contentDocument.getElementById('owned'); true"
        )
        XCTAssertTrue(assigned)
        try await eventually("same-origin owning document loaded") {
            try await self.readFrame(
                "!!owned.contentDocument?.getElementById('field') && !!owned.contentWindow.events")
        }
        let retained: Bool = try await readFrame(
            "window.capturedField=owned.contentDocument.getElementById('field');"
                + "window.capturedEvents=owned.contentWindow.events; true")
        XCTAssertTrue(retained)
    }

    private func invalidateOwnedPicker(ancestor: Bool, navigation: Bool) async throws {
        try await installOwnedFrames()
        try await keyboardOpen("capturedField")
        let owner = ancestor ? "window.ancestor" : "owned"
        let html = ancestor ? ancestorHTML : localHTML
        let replacement = try quoted(html)
        let mutation =
            navigation ? "\(owner).srcdoc=\(replacement); true" : "\(owner).remove(); true"
        try await mutateFrame(
            owner, at: .leaf, method: navigation ? "Page.frameNavigated" : "Page.frameDetached",
            mutation: mutation)
        XCTAssertNil(
            pane.pageInput.forms.current, "changes on the same-origin captured path drop its picker"
        )
        await pane.pageInput.forms.choose(index: 1)
        let oldIndex: Int = try await readFrame("capturedField.selectedIndex")
        let oldEvents: [String] = try await readFrame("capturedEvents")
        XCTAssertEqual(oldIndex, 0)
        XCTAssertEqual(oldEvents, [])
        try await assertReplacementUnchanged(
            owner: owner, ancestor: ancestor, navigation: navigation)
    }

    private func assertReplacementUnchanged(
        owner: String, ancestor: Bool, navigation: Bool
    ) async throws {
        if !navigation {
            let parent = ancestor ? "document.body" : "window.ancestor.contentDocument.body"
            let reinserted: Bool = try await readFrame("\(parent).append(\(owner)); true")
            XCTAssertTrue(reinserted)
        }
        let doc =
            ancestor
            ? "window.ancestor.contentDocument?.getElementById('owned')?.contentDocument"
            : "owned.contentDocument"
        try await eventually("replacement same-origin document loaded") {
            try await self.readFrame(
                "!!\(doc)?.getElementById('field') && !!\(doc)?.defaultView.events")
        }
        let index: Int = try await readFrame("\(doc).getElementById('field').selectedIndex")
        let events: [String] = try await readFrame("\(doc).defaultView.events")
        XCTAssertEqual(index, 0)
        XCTAssertEqual(events, [])
    }

    private func quoted(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
