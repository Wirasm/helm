import HelmWire
import PocketKit
import SwiftUI

/// One chat (#625): the conversation read from the agent's transcript (`sessions/log`), newest at
/// the bottom, a multi-line field that types into the agent (`screen/send`), the waiting prompt's
/// choices as buttons, and the raw terminal one toggle away. A swipe moves to the next or previous
/// chat of the same workspace; the name opens the switcher.
struct ChatView: View {
    enum Mode: String { case chat, screen }

    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    /// The session id, as `sessions/all` and `sessions/log` name it.
    @State var chat: String
    @State private var mode = Mode.chat
    @State private var switching = false

    private var row: BenchSessionRow? {
        model.sessions.values.joined().first { $0.id == chat }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch mode {
            case .chat:
                // A pane per chat: a switch leaves the last one's state, and any answer still on
                // its way to it, behind.
                ChatPane(chat: chat, swipe: swipe).id(chat)
            case .screen:
                if let target = row?.screen { ScreenPane(target: target) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $switching) {
            SwitcherView { chat = $0 }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The connection, here too: the root's header is not on screen in a chat.
            if model.state != .connected {
                Text(model.state.word).font(Mono.small).foregroundStyle(model.state.color)
            }
            HStack(spacing: 10) {
                Button("‹") { dismiss() }.foregroundStyle(Palette.dim)
                Button {
                    switching = true
                } label: {
                    HStack(spacing: 6) {
                        if let row {
                            let attention = Attention(row)
                            Text(attention.glyph).foregroundStyle(Palette.of(attention))
                        }
                        Text(row?.title ?? chat).foregroundStyle(Palette.text).lineLimit(1)
                        Text("▾").foregroundStyle(Palette.faint)
                    }
                }
                Spacer()
                Button(mode == .chat ? "screen" : "chat") {
                    mode = mode == .chat ? .screen : .chat
                }
                .foregroundStyle(Palette.dim)
            }
            .font(Mono.body)
        }
    }

    /// The chat `step` places from this one in its workspace (1 the next, -1 the previous).
    private func swipe(_ step: Int) {
        let sections = PocketHome.sections(
            workspaces: model.workspaces, sessions: model.sessions, query: "")
        if let next = PocketHome.neighbor(of: chat, in: sections, step: step) { chat = next.id }
    }

}

/// One chat's conversation, its waiting prompt's choices and its field. Its state is this chat's
/// alone (`ChatView` gives each chat a pane of its own).
struct ChatPane: View {
    @EnvironmentObject private var model: PocketModel
    @EnvironmentObject private var memory: ChatMemory
    let chat: String
    /// Moves to the chat a step away: a swipe on the messages, never on the field or the choices.
    let swipe: (Int) -> Void
    @State private var log = ChatLog()
    @State private var prompt: PromptChoices?
    @State private var failure: String?
    @State private var linkFailure: String?
    @State private var page: PocketPage?
    /// The keyboard: the field takes it, and the messages give it back (a tap, or a scroll that
    /// drags it down).
    @FocusState private var typing: Bool

    private var row: BenchSessionRow? {
        model.sessions.values.joined().first { $0.id == chat }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failure { Text(failure).font(Mono.small).foregroundStyle(Palette.asking) }
            if let linkFailure {
                Text(linkFailure).font(Mono.small).foregroundStyle(Palette.asking)
            }
            MessagesView(log: $log, chat: chat)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(swiping)
            if let prompt, let target = row?.screen {
                ChoicesBar(shown: $prompt, prompt: prompt, target: target)
            }
            Composer(chat: chat, target: row?.screen, typing: $typing)
        }
        .task { await follow() }
        .task(id: model.state) {
            guard model.state == .connected else { return }
            linkFailure = await model.loadStoreLinks()?.description
        }
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard url.scheme == StoreLinks.scheme else { return .systemAction }
                guard let document = model.storeLinks.page(at: url) else { return .discarded }
                typing = false
                page = document
                return .handled
            }
        )
        .navigationDestination(item: $page) { PageView(page: $0) }
    }

    /// Left for the next chat of this workspace, right for the previous. Not from the left edge,
    /// which is the back swipe to the list.
    private var swiping: some Gesture {
        DragGesture(minimumDistance: 40).onEnded { drag in
            let dx = drag.translation.width
            guard drag.startLocation.x > 40, abs(dx) > 90,
                abs(dx) > 2 * abs(drag.translation.height)
            else { return }
            swipe(dx < 0 ? 1 : -1)
        }
    }

    /// The last page, then every second and a half whatever came after it; and, while the agent
    /// waits on a prompt, its choices off the screen. Having the chat open is reading it.
    private func follow() async {
        await load(.last, limit: ChatLog.page)
        if let row, Attention(row) == .finished {
            _ = await model.markSeen(harness: row.harness, session: row.id)
        }
        var behind = false
        while !Task.isCancelled {
            // Behind after a long burst (the phone slept): the next page at once.
            if !behind { try? await Task.sleep(for: .milliseconds(1500)) }
            behind = await load(
                log.newest.map { .after($0) } ?? .last,
                limit: log.newest == nil ? ChatLog.page : 50)
            prompt = await choices()
        }
    }

    /// Reads `page` into the chat; true when the transcript holds more after it.
    @discardableResult
    private func load(_ page: BenchSessionLogRequest.Page, limit: Int = 50) async -> Bool {
        switch await model.log(chat, page: page, limit: limit) {
        case let .success(next):
            failure = nil
            log.merge(next)
            guard let newest = log.newest else { return false }
            memory.read(chat, through: newest, of: next.total)
            return newest < next.total - 1
        case let .failure(why):
            failure = why.description
            return false
        }
    }

    private func choices() async -> PromptChoices? {
        guard let row, row.waitsAtPrompt, let target = row.screen,
            case let .success(screen) = await model.screen(target)
        else { return nil }
        return PromptChoices.read(screen.lines)
    }
}

/// The conversation, newest at the bottom; older pages load as he scrolls up to the top. The
/// chat never moves under him: a page landing above keeps what he is reading where it is on
/// screen, and the agent's new messages follow him down only while he is at the bottom; above
/// it, a pill counts them and takes him down.
///
/// A plain `VStack`, not a lazy one: on a long transcript `LazyVStack` re-placed its rows forever
/// at the bottom-anchored end (100% CPU, the chat frozen or blank, measured on a real 3,000-entry
/// transcript), because tall rows never matched the heights it estimated. Paging keeps the stack
/// to what he has scrolled through, so laying every row out is cheap.
struct MessagesView: View {
    @EnvironmentObject private var model: PocketModel
    @Binding var log: ChatLog
    let chat: String
    @State private var position = ScrollPosition(edge: .bottom)
    /// The view's bottom edge is at the content's, within a few points.
    @State private var atBottom = true
    /// The newest entry when he left the bottom: entries after it are the pill's count.
    @State private var leftAt: Int?
    /// An older page is being put in above him: when the content grows, the view moves down by
    /// as much, so what he reads stays where it is on screen.
    @State private var prepending = false
    /// The scroll offset, as last seen: where he was before the page above was laid out.
    @State private var offset: CGFloat = 0
    @State private var loadingOlder = false
    /// Failed asks for the page above: each one gives the top row a new identity, so it looks
    /// again whether he can see it and retries.
    @State private var olderFailures = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if log.hasOlder {
                    // Reaching the top asks for the page above. A plain stack lays out every row
                    // at once, so `onAppear` would fire at open; the row's place in the scroll
                    // view's own frame says whether he can see it.
                    // One height loading or not: a row that shrank as the page landed would move
                    // everything below it, after the move that keeps his place (measured).
                    Text("…").font(Mono.small)
                        .foregroundStyle(Palette.faint).opacity(loadingOlder ? 1 : 0)
                        .frame(maxWidth: .infinity)
                        .onGeometryChange(for: Bool.self) {
                            $0.frame(in: .named(Self.space)).maxY >= 0
                        } action: { visible in
                            if visible { Task { await older() } }
                        }
                        // A new row after a failed ask, so it looks again and retries. Not one
                        // per page: a fresh row measures itself before the page above is placed,
                        // and that chained every page of the transcript in at once (measured).
                        .id("older-\(olderFailures)")
                }
                ForEach(log.entries) { MessageRow(entry: $0).id($0.index) }
            }
            .padding(.vertical, 6)
        }
        .coordinateSpace(.named(Self.space))
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // When the content grows at the bottom he follows it down only from the bottom; reading
        // above it, the top holds, so new messages land out of sight.
        .defaultScrollAnchor(atBottom ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentOffset.y
        } action: { _, y in
            offset = y
        }
        .onScrollGeometryChange(for: Bool.self) {
            $0.visibleRect.maxY >= $0.contentSize.height - Self.bottomSlack
        } action: { _, bottom in
            atBottom = bottom
            leftAt = bottom ? nil : (leftAt ?? log.newest)
        }
        // A page put in above grew the content by its height: move down by as much.
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentSize.height
        } action: { old, new in
            guard prepending else { return }
            prepending = false
            position.scrollTo(y: offset + new - old)
        }
        .overlay(alignment: .bottom) {
            if fresh > 0 {
                Button {
                    withAnimation { position.scrollTo(edge: .bottom) }
                } label: {
                    Text("↓ \(fresh) new").font(Mono.small).foregroundStyle(Palette.background)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Palette.finished))
                }
                .padding(.bottom, 8)
            }
        }
    }

    private static let space = "messages"
    /// How close to the content's end still counts as the bottom.
    private static let bottomSlack: CGFloat = 12

    /// Entries that arrived since he left the bottom.
    private var fresh: Int {
        guard !atBottom, let leftAt else { return 0 }
        return log.entries.reversed().prefix { $0.index > leftAt }.count
    }

    private func older() async {
        guard !loadingOlder, let oldest = log.oldest else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        guard
            case let .success(page) = await model.log(
                chat, page: .before(oldest), limit: ChatLog.page)
        else {
            // benchd unreachable for a moment: wait, then look again.
            try? await Task.sleep(for: .seconds(2))
            olderFailures += 1
            return
        }
        prepending = true
        log.merge(page)
    }
}

/// One transcript entry as a message: his prompts on the right in their own colour, the agent's
/// replies as markdown, each with its time under it; a tool call as one dim line, an error
/// in the asking colour, a message another session sent as one line naming it; what a slash
/// command printed as one faint line under it, and a compaction as a divider. Each can be
/// selected in part and copied, or copied whole (`SelectableText`).
struct MessageRow: View {
    @EnvironmentObject private var model: PocketModel
    let entry: BenchLogEntry

    var body: some View {
        switch entry.kind {
        case .user:
            if let from = entry.from {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SelectableText(
                        text: "✉ \(from)  \(entry.text)", font: Mono.smallUI,
                        color: Palette.dim, lines: 1, copy: entry.text)
                    stamp
                }
            } else {
                HStack {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 2) {
                        SelectableText(
                            text: entry.text, font: Mono.bodyUI,
                            color: Palette.finished)
                        stamp
                    }
                }
            }
        case .agent:
            VStack(alignment: .leading, spacing: 2) {
                SelectableText(
                    text: entry.text, markdown: true, font: Mono.bodyUI, color: Palette.text,
                    links: model.storeLinks)
                stamp
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            SelectableText(
                text: "· \(entry.tool ?? "tool")  \(entry.text)",
                font: Mono.smallUI, color: Palette.faint, lines: 1, copy: entry.text)
        case .error:
            SelectableText(
                text: "✗ \(entry.tool.map { "\($0): " } ?? "")\(entry.text)",
                font: Mono.smallUI, color: Palette.asking, lines: 3, copy: entry.text)
        case .result:
            // Under the slash command he typed, on his side: it ran, and what it said.
            let said = entry.text.split(separator: "\n").first.map(String.init) ?? ""
            Text("✓ \(said.isEmpty ? "done" : said)").font(Mono.small)
                .foregroundStyle(Palette.faint).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .compacted:
            Text("— compacted —").font(Mono.small).foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity)
        }
    }

    /// When the entry was written, in the phone's time zone and clock (hh:mm).
    private var stamp: some View {
        Text(
            Date(timeIntervalSince1970: Double(entry.atMs) / 1000)
                .formatted(date: .omitted, time: .shortened)
        )
        .font(Mono.stamp).foregroundStyle(Palette.faint)
    }

    /// Inline markdown (bold, code, links), line breaks kept as written, for a line in the chats
    /// list (a chat draws its replies' blocks too, `ChatText`); anything it cannot read stays plain
    /// text.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
