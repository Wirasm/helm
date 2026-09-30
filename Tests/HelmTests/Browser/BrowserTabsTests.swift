import XCTest

@testable import Helm

/// Which tab the pane shows. It stays where the operator is (#542): an agent's tab waits in
/// the strip, badged and marked, until he looks or turns Follow on.
final class BrowserTabsTests: XCTestCase {
    private func page(
        _ id: String, _ url: String = "https://a.test", opener: String? = nil
    )
        -> BrowserTab
    {
        BrowserTab(targetId: id, type: "page", url: url, title: "", openerId: opener)
    }

    private func showingMain() -> BrowserTabs {
        var tabs = BrowserTabs()
        _ = tabs.replaceAll(with: [page("main"), page("other")])
        _ = tabs.show("main")
        return tabs
    }

    func testOnConnectItShowsATabAndIgnoresTargetsThatAreNotTabs() {
        var tabs = BrowserTabs()
        let worker = BrowserTab(
            targetId: "sw", type: "service_worker", url: "chrome-extension://x/sw.js", title: "")
        XCTAssertEqual(tabs.replaceAll(with: [page("a"), worker]), .show("a"))
        XCTAssertEqual(tabs.tabs.map(\.targetId), ["a"], "an extension's worker is not a tab")
        XCTAssertEqual(tabs.fromOutside, [], "a tab that was already there carries no mark")
    }

    /// The hijack #542 removes: `playwright-cli tab-new` used to take the pane.
    func testAnAgentsNewTabDoesNotTakeOverThePane() {
        var tabs = showingMain()
        XCTAssertEqual(tabs.created(page("agent", "https://b.test")), .stay)
        XCTAssertEqual(tabs.showing, "main", "the operator stays on his tab")
        XCTAssertEqual(tabs.unseen, ["agent"], "the new tab is badged")
        XCTAssertEqual(tabs.fromOutside, ["agent"], "and marked as opened from outside")
    }

    func testANavigationInAnotherTabIsBadgedNotShown() {
        var tabs = showingMain()
        XCTAssertEqual(tabs.changed(page("other", "https://c.test")), .stay)
        XCTAssertEqual(tabs.showing, "main")
        XCTAssertEqual(tabs.unseen, ["other"])
        XCTAssertEqual(tabs.fromOutside, [], "a navigation says nothing about who opened it")
        XCTAssertEqual(tabs.changed(page("main", "https://a.test")), .stay, "title-only")
        XCTAssertEqual(tabs.show("other"), .show("other"))
        XCTAssertEqual(tabs.unseen, [], "looking clears the badge")
    }

    func testFollowShowsEveryTabThatOpensOrNavigates() {
        var tabs = showingMain()
        tabs.follow = true
        XCTAssertEqual(tabs.created(page("agent")), .show("agent"))
        XCTAssertEqual(tabs.changed(page("other", "https://c.test")), .show("other"))
        XCTAssertEqual(tabs.unseen, [])
    }

    /// CDP sends this pane's own `targetCreated` before the `createTarget` reply (measured), so
    /// the mark is provisional until the reply lands.
    func testTheOperatorsOwnTabIsShownAndUnmarkedWhicheverArrivesFirst() {
        var eventFirst = showingMain()
        XCTAssertEqual(eventFirst.created(page("mine")), .stay)
        XCTAssertEqual(eventFirst.ownCreated("mine"), .show("mine"))
        XCTAssertEqual(eventFirst.fromOutside, [])
        XCTAssertEqual(eventFirst.unseen, [])

        var replyFirst = showingMain()
        XCTAssertEqual(replyFirst.ownCreated("mine"), .stay)
        XCTAssertEqual(replyFirst.created(page("mine")), .show("mine"))
        XCTAssertEqual(replyFirst.fromOutside, [])
    }

    func testAPopupFromThePageOnScreenIsShownAndItsCloseReturnsToItsOpener() {
        var tabs = showingMain()
        XCTAssertEqual(tabs.created(page("popup", opener: "main")), .show("popup"))
        XCTAssertEqual(tabs.fromOutside, [])
        XCTAssertEqual(
            tabs.destroyed("popup"), .show("main"),
            "an OAuth popup closing hands the flow back to its opener")
    }

    func testAPopupFromAnAgentsTabIsTheAgentsToo() {
        var tabs = showingMain()
        _ = tabs.created(page("agent"))
        XCTAssertEqual(tabs.created(page("popup", opener: "agent")), .stay)
        XCTAssertEqual(tabs.fromOutside, ["agent", "popup"])
    }

    func testClosingTheShownTabShowsTheOneThatTookItsPlace() {
        var tabs = BrowserTabs()
        _ = tabs.replaceAll(with: [page("a"), page("b"), page("c")])
        _ = tabs.show("b")
        XCTAssertEqual(tabs.destroyed("b"), .show("c"), "not the newest, the neighbour")
        XCTAssertEqual(tabs.destroyed("c"), .show("a"), "the last closing goes left")
    }

    /// Chrome sends no event when a page's title arrives after its navigation, so the pane
    /// re-reads titles from the list. A retitle changes titles and nothing else.
    func testARetitleUpdatesTitlesOnly() {
        var tabs = showingMain()
        var renamed = page("other", "https://elsewhere.test")
        renamed.title = "Pricing"
        tabs.retitle(from: [renamed, page("unknown")])
        XCTAssertEqual(tabs.tabs.map(\.title), ["", "Pricing"])
        XCTAssertEqual(tabs.tabs.map(\.url), ["https://a.test", "https://a.test"])
        XCTAssertEqual(tabs.tabs.count, 2, "a tab only the list knows is the events' to add")
        XCTAssertEqual(tabs.unseen, [], "a title is not activity")
    }

    func testClosingTheLastTabAsksForABlankOne() {
        var tabs = BrowserTabs()
        _ = tabs.replaceAll(with: [page("only")])
        XCTAssertEqual(tabs.destroyed("only"), .openBlank)
    }

    func testTheOperatorsPickStands() {
        var tabs = BrowserTabs()
        _ = tabs.replaceAll(with: [page("a"), page("b")])
        XCTAssertEqual(tabs.show("a"), .show("a"))
        XCTAssertEqual(tabs.show("a"), .stay, "already showing it")
        XCTAssertEqual(
            tabs.replaceAll(with: [page("a"), page("b")]), .stay, "a reconnect keeps it")
    }
}
