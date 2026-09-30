import SwiftUI

/// The shared browser's tabs, as a strip across the top of the pane (#542).
///
/// **Narrow panes scroll rather than squeeze.** Tabs share the width down to a floor where a
/// title is still a few readable characters, and past that the strip scrolls sideways with the
/// shown tab kept in view. The operator runs two columns and a drawer on a 14-inch screen, so
/// "narrow" is the normal case, not the edge.
struct BrowserTabStrip: View {
    @ObservedObject var model: BrowserPaneModel

    static let widest: CGFloat = 180
    static let narrowest: CGFloat = 96
    private static let gap: CGFloat = 2

    /// Each tab's width: an equal share of the strip, between the floor and the ceiling.
    static func tabWidth(available: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return widest }
        let share = (available - gap * CGFloat(count - 1)) / CGFloat(count)
        return min(widest, max(narrowest, share))
    }

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geometry in
                tabs(
                    width: Self.tabWidth(
                        available: geometry.size.width, count: model.tabs.tabs.count))
            }
            unseen
            Button(action: model.newTab) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .help("New tab (⌘T)")
            follow
        }
        .buttonStyle(.chrome)
        .foregroundStyle(Color.textMuted)
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(Color.surfaceRaised)
    }

    private func tabs(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.gap) {
                    ForEach(model.tabs.tabs) { tab in
                        BrowserTabChip(
                            tab: tab, isShown: tab.targetId == model.tabs.showing,
                            isUnseen: model.tabs.unseen.contains(tab.targetId),
                            isAsking: model.dialogs[tab.targetId] != nil,
                            fromOutside: model.tabs.fromOutside.contains(tab.targetId),
                            loading: tab.targetId == model.tabs.showing && model.loading,
                            select: { model.show(tab: tab.targetId) },
                            close: { model.close(tab: tab.targetId) }
                        )
                        .frame(width: width)
                        .id(tab.targetId)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            // The shown tab is brought into view when it changes and when the strip's layout
            // does (tabs coming and going, the pane resizing). After a yield, because a scroll
            // asked for in the same update as the change lands on the old layout: measured, the
            // shown tab ended up half off a narrow strip.
            .task(
                id: ScrollKey(shown: model.tabs.showing, count: model.tabs.tabs.count, width: width)
            ) {
                await Task.yield()
                if let shown = model.tabs.showing { proxy.scrollTo(shown, anchor: .center) }
            }
        }
    }

    private struct ScrollKey: Equatable {
        let shown: String?
        let count: Int
        let width: CGFloat
    }

    /// How many tabs changed out of sight, so a badged tab scrolled off a narrow strip is still
    /// seen. Clicking it shows the newest of them: the operator asked.
    @ViewBuilder
    private var unseen: some View {
        let waiting = model.tabs.tabs.filter { model.tabs.unseen.contains($0.targetId) }
        if let newest = waiting.last {
            Button {
                model.show(tab: newest.targetId)
            } label: {
                HStack(spacing: 3) {
                    Circle().fill(Color.accent).frame(width: 6, height: 6)
                    Text("\(waiting.count) new")
                }
                .font(.system(size: 11))
                .padding(.horizontal, 6)
                .frame(height: 22)
            }
            .foregroundStyle(Color.accent)
            .help("Tabs that opened or changed while you were here. Click to show the newest.")
        }
    }

    private var follow: some View {
        let on = model.tabs.follow
        return Button(action: model.toggleFollow) {
            HStack(spacing: 3) {
                Image(systemName: on ? "eye.fill" : "eye")
                Text("Follow")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5).fill(on ? Color.selection : .clear))
        }
        .foregroundStyle(on ? Color.accent : Color.textMuted)
        .help(
            on
                ? "Following: the pane shows each tab as it opens or navigates. Click to stay on "
                    + "the tab you pick."
                : "Follow: show each tab as it opens or navigates, to watch an agent work. Off, "
                    + "new tabs wait in the strip with a dot.")
    }
}

/// One tab in the strip: its state marks, its title, and its ×.
private struct BrowserTabChip: View {
    let tab: BrowserTab
    let isShown: Bool
    let isUnseen: Bool
    /// The page raised a dialog nobody has answered (#544).
    let isAsking: Bool
    let fromOutside: Bool
    let loading: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if isAsking {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.attention)
                    .help("The page is asking something and waits for an answer. Show the tab.")
            } else if loading {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            } else if isUnseen {
                Circle().fill(Color.accent).frame(width: 6, height: 6)
                    .help("Changed since you last looked")
            }
            if fromOutside {
                Image(systemName: "sparkle")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.accent)
                    .help(
                        "Opened from outside this pane: by an agent through Playwright, or "
                            + "another helm pane")
            }
            Text(BrowserTabChip.title(of: tab))
                .font(.system(size: 11.5, weight: isShown ? .semibold : .regular))
                .foregroundStyle(isShown ? Color.textPrimary : Color.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            // Only where it can be meant, so a narrow tab spends its width on the title.
            if isShown || hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                }
                .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(isShown ? Color.selection : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(tab.url)
    }

    /// The page's title; before it has one, its host; a blank tab is a new tab.
    static func title(of tab: BrowserTab) -> String {
        if !tab.title.isEmpty, tab.title != tab.url { return tab.title }
        if tab.url == "about:blank" { return "New Tab" }
        return URL(string: tab.url)?.host() ?? tab.url
    }
}
