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

    private var row: BenchSessionRow? {
        model.sessions.values.joined().first { $0.id == chat }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failure { Text(failure).font(Mono.small).foregroundStyle(Palette.asking) }
            MessagesView(log: $log, chat: chat).simultaneousGesture(swiping)
            if let prompt, let target = row?.screen {
                ChoicesBar(shown: $prompt, prompt: prompt, target: target)
            }
            Composer(chat: chat, target: row?.screen)
        }
        .task { await follow() }
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
        await load(.last)
        if let row, Attention(row) == .finished {
            _ = await model.markSeen(harness: row.harness, session: row.id)
        }
        var behind = false
        while !Task.isCancelled {
            // Behind after a long burst (the phone slept): the next page at once.
            if !behind { try? await Task.sleep(for: .milliseconds(1500)) }
            behind = await load(log.newest.map { .after($0) } ?? .last)
            prompt = await choices()
        }
    }

    /// Reads `page` into the chat; true when the transcript holds more after it.
    @discardableResult
    private func load(_ page: BenchSessionLogRequest.Page) async -> Bool {
        switch await model.log(chat, page: page) {
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

/// The conversation, newest at the bottom and kept there as entries arrive; older pages load from
/// the top.
struct MessagesView: View {
    @EnvironmentObject private var model: PocketModel
    @Binding var log: ChatLog
    let chat: String
    /// The entry at the bottom of the view: new entries scroll in only while it is the newest,
    /// so reading back is not pulled down by the agent's next line.
    @State private var shown: Int?

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if log.hasOlder {
                        Button("earlier") { Task { await older(reader) } }
                            .font(Mono.small).foregroundStyle(Palette.faint)
                    }
                    ForEach(log.entries) { MessageRow(entry: $0).id($0.index) }
                }
                .scrollTargetLayout()
                .padding(.vertical, 6)
            }
            .defaultScrollAnchor(.bottom)
            .scrollPosition(id: $shown, anchor: .bottom)
            .onChange(of: log.newest) { old, newest in
                guard let newest, shown == nil || shown == old else { return }
                reader.scrollTo(newest, anchor: .bottom)
            }
        }
    }

    private func older(_ reader: ScrollViewProxy) async {
        guard let oldest = log.oldest,
            case let .success(page) = await model.log(chat, page: .before(oldest))
        else { return }
        log.merge(page)
        // Where he was reading stays where it was: the older page goes above it.
        reader.scrollTo(oldest, anchor: .top)
    }
}

/// One transcript entry as a message: his prompts on the right in their own colour, the agent's
/// replies as simple markdown, a tool call as one dim line, an error in the asking colour.
struct MessageRow: View {
    let entry: BenchLogEntry

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text).font(Mono.body).foregroundStyle(Palette.finished)
                    .textSelection(.enabled)
            }
        case .agent:
            Text(Self.markdown(entry.text)).font(Mono.body).foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Text("· \(entry.tool ?? "tool")  \(entry.text)").font(Mono.small)
                .foregroundStyle(Palette.faint).lineLimit(1)
        case .error:
            Text("✗ \(entry.tool.map { "\($0): " } ?? "")\(entry.text)").font(Mono.small)
                .foregroundStyle(Palette.asking).lineLimit(3)
        }
    }

    /// Inline markdown (bold, code, links), line breaks kept as written; anything it cannot read
    /// stays plain text.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
