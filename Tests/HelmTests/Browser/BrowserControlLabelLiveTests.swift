import XCTest

@testable import Helm

@MainActor
final class BrowserControlLabelLiveTests: BrowserControlLiveCase {
    private func activate(
        _ kind: String, target: String, cancel: Bool = true, stop: Bool = false
    ) async throws {
        let field =
            kind == "select"
            ? "<select id=field><option>First</option><option>Second</option></select>"
            : "<input id=field type=date>"
        try await show(
            """
            <label id=label for=field style='display:block;width:220px;height:40px'>
              <span id=child style='display:inline-block;width:50px'>Choose</span></label>
            \(field)
            <script>window.clicks=0; window.drained=false;
              field.addEventListener('click', e=>{clicks++;
                if (\(cancel)) e.preventDefault(); if (\(stop)) e.stopImmediatePropagation();
              }, {capture:\(stop)});
              document.addEventListener('keyup',()=>window.drained=true);
            </script>
            """)
        try await click(target)
        if cancel {
            pane.key(
                .init(
                    type: "keyUp", modifiers: 0, key: "F8", code: "F8", windowsVirtualKeyCode: 119))
            // This queued event is a barrier: an incorrectly open picker swallows it.
            try await eventually("forwarded cancellation leaves following page input usable") {
                try await self.read("drained", as: Bool.self)
            }
            XCTAssertNil(pane.pageInput.forms.current)
        } else {
            try await eventually("uncanceled label opens picker") {
                self.pane.pageInput.forms.current != nil
            }
            if kind == "select" {
                await pane.pageInput.forms.choose(index: 1)
            } else {
                await pane.pageInput.forms.choose(date: "2026-10-02")
            }
            XCTAssertNil(pane.pageInput.forms.current)
            let value = try await read("field.value", as: String.self)
            XCTAssertEqual(value, kind == "select" ? "Second" : "2026-10-02")
        }
        let clicks = try await read("clicks", as: Int.self)
        XCTAssertEqual(clicks, 1, "do not dispatch a second control click")
    }

    func testSelectLabelHonorsForwardedCancellation() async throws {
        try await activate("select", target: "label")
    }
    func testSelectLabelChildHonorsForwardedCancellation() async throws {
        try await activate("select", target: "child")
    }
    func testDateLabelHonorsForwardedCancellation() async throws {
        try await activate("date", target: "label")
    }
    func testDateLabelChildHonorsForwardedCancellation() async throws {
        try await activate("date", target: "child")
    }
    func testSelectLabelHonorsImmediateCaptureCancellation() async throws {
        try await activate("select", target: "label", stop: true)
    }
    func testDateLabelHonorsImmediateCaptureCancellation() async throws {
        try await activate("date", target: "label", stop: true)
    }
    func testUncanceledSelectLabelStillOpensAndCommitsOnce() async throws {
        for target in ["label", "child"] {
            try await activate("select", target: target, cancel: false)
        }
    }
    func testUncanceledDateLabelStillOpensAndCommitsOnce() async throws {
        for target in ["label", "child"] {
            try await activate("date", target: target, cancel: false)
        }
    }
    func testSelectCapturePropagationAloneStillAllowsDefault() async throws {
        try await activate("select", target: "label", cancel: false, stop: true)
    }
    func testDateCapturePropagationAloneStillAllowsDefault() async throws {
        try await activate("date", target: "label", cancel: false, stop: true)
    }
}
