import XCTest

@testable import Helm

/// Which tab the pane shows. The pane is how the operator watches agents, so it follows
/// where the work happens, and returns to a popup's opener when the popup closes.
final class BrowserTabsTests: XCTestCase {
    private func page(
        _ id: String, _ url: String = "https://a.test", opener: String? = nil
    )
        -> BrowserTab
    {
        BrowserTab(targetId: id, type: "page", url: url, title: "", openerId: opener)
    }

    func testOnConnectItShowsATabAndIgnoresTargetsThatAreNotTabs() {
        var tabs = BrowserTabs()
        let worker = BrowserTab(
            targetId: "sw", type: "service_worker", url: "chrome-extension://x/sw.js", title: "")
        XCTAssertEqual(tabs.replaceAll(with: [page("a"), worker]), .show("a"))
        XCTAssertEqual(tabs.tabs.map(\.targetId), ["a"], "an extension's worker is not a tab")
    }

    func testANewTabIsFollowedAndItsCloseReturnsToTheTabThatOpenedIt() {
        var tabs = BrowserTabs()
        _ = tabs.replaceAll(with: [page("main"), page("other")])
        _ = tabs.show("main")
        XCTAssertEqual(tabs.created(page("popup", opener: "main")), .show("popup"))
        XCTAssertEqual(
            tabs.destroyed("popup"), .show("main"),
            "an OAuth popup closing hands the flow back to its opener")
    }

    func testANavigationInAnotherTabBringsThatTabForward() {
        var tabs = BrowserTabs()
        _ = tabs.replaceAll(with: [page("shown"), page("agent", "about:blank")])
        _ = tabs.show("shown")
        XCTAssertEqual(
            tabs.changed(page("agent", "https://example.com")), .show("agent"),
            "an agent's goto lands in its own tab, which is where the operator wants to look")
        XCTAssertEqual(
            tabs.changed(page("shown", "https://a.test")), .stay,
            "a title-only change moves nothing")
    }

    func testClosingTheLastTabAsksForABlankOne() {
        var tabs = BrowserTabs()
        _ = tabs.replaceAll(with: [page("only")])
        XCTAssertEqual(tabs.destroyed("only"), .openBlank)
    }

    func testTheOperatorsPickStandsUntilSomethingHappens() {
        var tabs = BrowserTabs()
        _ = tabs.replaceAll(with: [page("a"), page("b")])
        XCTAssertEqual(tabs.show("a"), .show("a"))
        XCTAssertEqual(tabs.show("a"), .stay, "already showing it")
        XCTAssertEqual(
            tabs.replaceAll(with: [page("a"), page("b")]), .stay, "a reconnect keeps it")
    }
}
