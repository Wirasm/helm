import Foundation

/// One page target in the shared browser — a tab, as CDP reports it.
struct BrowserTab: Codable, Equatable, Identifiable {
    let targetId: String
    var type: String
    var url: String
    var title: String
    /// The tab that opened this one, for a popup or `window.open` (an OAuth window is one).
    var openerId: String?

    var id: String { targetId }
}

/// Which tab the pane shows, as a pure function of what the browser reports.
///
/// **The rule is "follow the activity"**, because the pane is how the operator watches what
/// agents do. A tab that opens (`playwright-cli tab-new`, a `window.open`, an OAuth popup) or
/// navigates is where the work is, so the pane goes there; when the tab it shows closes, the
/// pane goes back to the tab that opened it, which is where a popup's flow returns. The
/// operator can pick any tab by hand, and that stands until the next one opens or navigates.
///
/// Kept free of the socket so every rule is a test, not a live browser.
struct BrowserTabs: Equatable {
    /// Oldest first.
    private(set) var tabs: [BrowserTab] = []
    private(set) var showing: String?

    enum Decision: Equatable {
        case stay
        case show(String)
        /// Every tab is gone: open a blank one so there is something to show.
        case openBlank
    }

    /// Pages only. A service worker, an extension's background page and chrome://-internal
    /// UI (the omnibox popup a headless Chrome still reports) are targets, not tabs.
    static func isTab(_ tab: BrowserTab) -> Bool {
        tab.type == "page" && !tab.url.hasPrefix("devtools://")
    }

    /// The browser's full list, on connect. Keeps showing what it was showing if that tab is
    /// still there; otherwise the most recent tab.
    mutating func replaceAll(with reported: [BrowserTab]) -> Decision {
        tabs = reported.filter(Self.isTab)
        if let showing, tabs.contains(where: { $0.targetId == showing }) { return .stay }
        return fallback(preferring: nil)
    }

    mutating func created(_ tab: BrowserTab) -> Decision {
        guard Self.isTab(tab), !tabs.contains(where: { $0.targetId == tab.targetId }) else {
            return .stay
        }
        tabs.append(tab)
        return show(tab.targetId)
    }

    mutating func changed(_ tab: BrowserTab) -> Decision {
        guard let index = tabs.firstIndex(where: { $0.targetId == tab.targetId }) else {
            return created(tab)
        }
        // A target that stops being a tab (rare: a prerender swapped in) is a destroy.
        guard Self.isTab(tab) else { return destroyed(tab.targetId) }
        let navigated = tabs[index].url != tab.url
        tabs[index] = tab
        // A tab that navigates is a tab somebody is working in — an agent's `goto` lands in
        // whichever tab its own session holds, which need not be the one on screen.
        return navigated ? show(tab.targetId) : .stay
    }

    mutating func destroyed(_ targetId: String) -> Decision {
        guard let index = tabs.firstIndex(where: { $0.targetId == targetId }) else { return .stay }
        let gone = tabs.remove(at: index)
        guard showing == targetId else { return .stay }
        showing = nil
        return fallback(preferring: gone.openerId)
    }

    /// The operator picked a tab, or the pane attached to one.
    mutating func show(_ targetId: String) -> Decision {
        guard tabs.contains(where: { $0.targetId == targetId }) else { return .stay }
        guard showing != targetId else { return .stay }
        showing = targetId
        return .show(targetId)
    }

    var current: BrowserTab? { tabs.first { $0.targetId == showing } }

    private mutating func fallback(preferring opener: String?) -> Decision {
        if let opener, tabs.contains(where: { $0.targetId == opener }) { return show(opener) }
        guard let newest = tabs.last else {
            showing = nil
            return .openBlank
        }
        return show(newest.targetId)
    }
}
