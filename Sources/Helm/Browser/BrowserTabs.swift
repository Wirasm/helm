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
/// **The rule is "stay where the operator is"** (#542, #125's *appear, don't seize*). Agents
/// open and navigate tabs in the same browser all the time; the pane used to jump to each one,
/// and the operator lost his place mid-sentence. Now a tab that opens or navigates while he
/// looks at another is marked `unseen` and waits in the strip. The pane moves only when he
/// asked: a tab he opened (⌘T, +, a ⌘-clicked link), a popup from the page he is on (an OAuth
/// window), a tab he picked, or — with `follow` on — every tab that opens or navigates, which
/// is the old rule kept as a choice for watching an agent work.
///
/// **`fromOutside` is the agent marker, and it means only what CDP can tell** (measured in
/// #542's spike): a tab with no opener that this pane did not create was made by another CDP
/// client — on this bench, an agent through Playwright, or another helm pane — and a popup
/// from such a tab inherits the mark. `attached` cannot say more: Playwright attaches to every
/// page, so it marks all of them. Which tab an agent is *driving* right now is not knowable
/// from here, and tabs that existed before the pane connected carry no mark.
///
/// Kept free of the socket so every rule is a test, not a live browser.
struct BrowserTabs: Equatable {
    /// Oldest first.
    private(set) var tabs: [BrowserTab] = []
    private(set) var showing: String?
    /// Tabs that opened or navigated while the pane showed another, until the operator looks.
    private(set) var unseen: Set<String> = []
    /// Tabs opened from outside this pane (see the header).
    private(set) var fromOutside: Set<String> = []
    /// Show every tab that opens or navigates, as the pane did before #542.
    var follow = false
    /// Tabs this pane created whose `targetCreated` has not arrived yet. CDP sends the event
    /// about 5 ms *before* the `createTarget` reply, so this is normally empty; it covers the
    /// other order.
    private var ownPending: Set<String> = []

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
    /// still there; otherwise the most recent tab. Marks survive for the tabs still present.
    mutating func replaceAll(with reported: [BrowserTab]) -> Decision {
        tabs = reported.filter(Self.isTab)
        let ids = Set(tabs.map(\.targetId))
        unseen.formIntersection(ids)
        fromOutside.formIntersection(ids)
        if let showing, ids.contains(showing) { return .stay }
        showing = nil
        return tabs.last.map { show($0.targetId) } ?? .openBlank
    }

    mutating func created(_ tab: BrowserTab) -> Decision {
        guard Self.isTab(tab), !tabs.contains(where: { $0.targetId == tab.targetId }) else {
            return .stay
        }
        tabs.append(tab)
        if ownPending.remove(tab.targetId) != nil { return show(tab.targetId) }
        if let opener = tab.openerId {
            if fromOutside.contains(opener) { fromOutside.insert(tab.targetId) }
            // A popup from the page he is looking at comes forward — a sign-in window he
            // clicked for, even in a tab an agent opened.
            if opener == showing { return show(tab.targetId) }
        } else {
            // Provisional when it is this pane's own: `ownCreated` clears it on the reply.
            fromOutside.insert(tab.targetId)
        }
        return notice(tab.targetId)
    }

    /// The reply to this pane's own `Target.createTarget`: the operator opened it, so show it.
    mutating func ownCreated(_ targetId: String) -> Decision {
        guard tabs.contains(where: { $0.targetId == targetId }) else {
            ownPending.insert(targetId)
            return .stay
        }
        fromOutside.remove(targetId)
        return show(targetId)
    }

    mutating func changed(_ tab: BrowserTab) -> Decision {
        guard let index = tabs.firstIndex(where: { $0.targetId == tab.targetId }) else {
            return created(tab)
        }
        // A target that stops being a tab (rare: a prerender swapped in) is a destroy.
        guard Self.isTab(tab) else { return destroyed(tab.targetId) }
        let navigated = tabs[index].url != tab.url
        tabs[index] = tab
        return navigated ? notice(tab.targetId) : .stay
    }

    mutating func destroyed(_ targetId: String) -> Decision {
        guard let index = tabs.firstIndex(where: { $0.targetId == targetId }) else { return .stay }
        let gone = tabs.remove(at: index)
        unseen.remove(targetId)
        fromOutside.remove(targetId)
        guard showing == targetId else { return .stay }
        showing = nil
        // Where a popup's flow returns; else the tab that slid into its place, as a browser does.
        if let opener = gone.openerId, tabs.contains(where: { $0.targetId == opener }) {
            return show(opener)
        }
        guard !tabs.isEmpty else { return .openBlank }
        return show(tabs[min(index, tabs.count - 1)].targetId)
    }

    /// The operator picked a tab, or the pane attached to one.
    mutating func show(_ targetId: String) -> Decision {
        guard tabs.contains(where: { $0.targetId == targetId }) else { return .stay }
        unseen.remove(targetId)
        guard showing != targetId else { return .stay }
        showing = targetId
        return .show(targetId)
    }

    /// Titles from a fresh `Target.getTargets`. Chrome reports a title change only with a
    /// navigation (measured: a page's `<title>` arriving after the commit sends no
    /// `targetInfoChanged`), so the pane asks for the list again to keep the strip's titles
    /// current. Titles only: which tabs exist and where they point is the events' to say.
    mutating func retitle(from reported: [BrowserTab]) {
        for fresh in reported {
            guard let index = tabs.firstIndex(where: { $0.targetId == fresh.targetId }),
                tabs[index].title != fresh.title
            else { continue }
            tabs[index].title = fresh.title
        }
    }

    var current: BrowserTab? { tabs.first { $0.targetId == showing } }

    /// Something happened in `targetId`: with `follow` the pane goes there, else it is badged.
    private mutating func notice(_ targetId: String) -> Decision {
        if follow { return show(targetId) }
        if targetId != showing { unseen.insert(targetId) }
        return .stay
    }
}
