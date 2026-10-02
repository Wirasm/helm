import XCTest

@testable import Helm

@MainActor
final class BrowserOOPIFLiveTests: BrowserOOPIFLiveCase {
    func testNestedSelectUsesScaledScrolledFrameGeometryAndExactEvents() async throws {
        for perspective in [false, true] {
            if perspective {
                let reset: Bool = try await readFrame(
                    "document.querySelector('#select').selectedIndex=0; events=[]; true")
                XCTAssertTrue(reset)
                for (level, owner, scale) in [(Level.main, "outer", 0.8), (.middle, "inner", 0.9)] {
                    let transformed: Bool = try await readFrame(
                        "document.querySelector('#\(owner)').style.transform='perspective(800px) rotateY(18deg) scale(\(scale))'; true",
                        at: level)
                    XCTAssertTrue(transformed)
                }
            }
            try await openSelect(perspective: perspective)
            await pane.pageInput.forms.choose(index: 2)
            let selected: Int = try await readFrame(
                "document.querySelector('#select').selectedIndex")
            let events: [String] = try await readFrame("events")
            XCTAssertEqual(
                selected, 2, "duplicate values must still select the intended option index")
            XCTAssertEqual(events, ["select:input", "select:change"])
            XCTAssertNil(pane.pageInput.forms.current)
        }
        try await assertUnchanged(at: .main)
        try await assertUnchanged(at: .middle)
    }

    func testNestedDateCommitsOnceAndEscapeAndCancelEmitNothing() async throws {
        try await clickLeaf("date")
        try await eventually("nested date picker opens") {
            self.pane.pageInput.forms.current != nil
        }
        await pane.pageInput.forms.choose(date: "2026-10-04")
        for escape in [true, false] {
            try await clickLeaf("date")
            try await eventually("date picker reopens") { self.pane.pageInput.forms.current != nil }
            if escape {
                key("Escape", code: "Escape", vk: 27)
            } else {
                pane.pageInput.forms.dismiss()
            }
            try await eventually("cancel drops date picker") {
                self.pane.pageInput.forms.current == nil
            }
            try await barrier()
        }
        let date: String = try await readFrame("document.querySelector('#date').value")
        let events: [String] = try await readFrame("events")
        XCTAssertEqual(date, "2026-10-04")
        XCTAssertEqual(events, ["date:input", "date:change"])
        try await assertUnchanged(at: .main)
        try await assertUnchanged(at: .middle)
    }

    func testKeyboardOpensFocusedNestedSelectAndSkipsDisabledOption() async throws {
        let focused: Bool = try await readFrame("document.querySelector('#select').focus(); true")
        XCTAssertTrue(focused)
        key(" ", code: "Space", vk: 32)
        try await eventually("keyboard opens nested select") {
            self.pane.pageInput.forms.current != nil
        }
        key("ArrowDown", code: "ArrowDown", vk: 40)
        key("Enter", code: "Enter", vk: 13)
        try await eventually("keyboard chooses nested option") {
            let selected: Int = try await self.readFrame(
                "document.querySelector('#select').selectedIndex")
            return selected == 2
        }
        try await eventually("committed picker is closed") {
            self.pane.pageInput.forms.current == nil
        }
        key(" ", code: "Space", vk: 32)
        try await eventually("keyboard picker reopens") { self.pane.pageInput.forms.current != nil }
        key("Escape", code: "Escape", vk: 27)
        try await barrier()
        let events: [String] = try await readFrame("events")
        XCTAssertEqual(events, ["select:input", "select:change"])
        try await assertUnchanged(at: .main)
        try await assertUnchanged(at: .middle)
    }

    func testCancelledNestedPageGestureKeepsPageInCharge() async throws {
        let ready: Bool = try await readFrame(
            "cancelGesture=true; document.querySelector('#select').focus(); true")
        XCTAssertTrue(ready)
        try await clickLeaf("select")
        try await barrier()
        let gestures: [String] = try await readFrame("gestures")
        XCTAssertEqual(gestures, ["mousedown", "click"])
        XCTAssertNil(pane.pageInput.forms.current)
        try await assertUnchanged()
    }

    func testReplacingTheCapturedElementNeverMutatesItsClone() async throws {
        try await openSelect()
        let replaced: Bool = try await readFrame("replaceSelect(); true")
        XCTAssertTrue(replaced)
        await pane.pageInput.forms.choose(index: 2)
        try await assertUnchanged()
        XCTAssertNotNil(pane.pageInput.forms.failure)
        pane.pageInput.forms.dismiss()
    }

    func testEscapeReleasesBothChildSessionsWhileTheTabRemainsOpen() async throws {
        try await openSelect()
        key("Escape", code: "Escape", vk: 27)
        try await barrier()
        XCTAssertNil(pane.pageInput.forms.current)
        try await assertUnchanged()
        try await closeChildObserversAndAssertNoAttachments()
    }

    func testNavigatingNestedFrameDropsPickerAndLeavesNewDocumentAlone() async throws {
        try await openSelect()
        let navigated: Bool = try await readFrame(
            "document.querySelector('#inner').src += '&replacement=1'; true", at: .middle)
        XCTAssertTrue(navigated)
        try await eventually("child navigation dismisses captured picker") {
            self.pane.pageInput.forms.current == nil
        }
        try await observeLeafAfterNavigation(replacement: true)
        await pane.pageInput.forms.choose(index: 2)
        try await assertUnchanged()
    }

    func testRemovingNestedFrameDropsPickerAndLeavesReinsertedFrameAlone() async throws {
        try await openSelect()
        let removed: Bool = try await readFrame(
            "window.removedFrame=document.querySelector('#inner'); removedFrame.remove(); true",
            at: .middle)
        XCTAssertTrue(removed)
        try await eventually("removed child dismisses captured picker") {
            self.pane.pageInput.forms.current == nil
        }
        let reinserted: Bool = try await readFrame(
            "document.body.append(removedFrame); true", at: .middle)
        XCTAssertTrue(reinserted)
        try await observeLeafAfterNavigation()
        await pane.pageInput.forms.choose(index: 2)
        try await assertUnchanged()
    }

    func testSwitchingTabsDropsPickerWithoutChangingOldChild() async throws {
        try await openSelect()
        let previous = try XCTUnwrap(pane.tabs.showing)
        pane.newTab()
        try await eventually("new tab is shown and picker is dropped") {
            self.pane.tabs.showing != previous && self.pane.pageInput.forms.current == nil
        }
        try ownCurrentTab()
        await pane.pageInput.forms.choose(index: 2)
        try await assertUnchanged()
    }

    func testNavigationDuringActivationLeavesNewFrameUsableWithoutStalePicker() async throws {
        let armed: Bool = try await readFrame(
            "document.querySelector('#select').addEventListener('mousedown',()=>location.href+='&replacement=1',{once:true}); true"
        )
        XCTAssertTrue(armed)
        try await clickLeaf("select")
        try await observeLeafAfterNavigation(replacement: true)
        let focused: Bool = try await readFrame("document.querySelector('#select').focus(); true")
        XCTAssertTrue(focused)
        try await barrier()
        XCTAssertNil(pane.pageInput.forms.current)
        try await assertUnchanged()
    }
}
