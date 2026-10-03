import HelmWire
import PocketKit
import SwiftUI

/// talk: one session's screen, live, with the keys row and a message box. The pills switch
/// between the sessions home lists.
struct TalkView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    @State var target: String
    @State private var screen: BenchScreen?
    @State private var unreachable: String?
    /// Why the last key or message was not taken, until one is.
    @State private var refused: String?
    /// A message is on its way to benchd.
    @State private var sending = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The connection, here too: the root's header is not on screen while talking.
            if model.state != .connected {
                Text(model.state.word).font(Mono.small).foregroundStyle(model.state.color)
            }
            pills
            // Top-left as a terminal draws, at least the viewport's size so a short screen does
            // not float in the middle; a wider or taller one scrolls, showing its bottom first.
            GeometryReader { viewport in
                ScrollView([.vertical, .horizontal]) {
                    Text((screen?.lines ?? []).joined(separator: "\n"))
                        .font(Mono.screen).foregroundStyle(Palette.text)
                        .fixedSize()
                        .frame(
                            minWidth: viewport.size.width, minHeight: viewport.size.height,
                            alignment: .topLeading)
                }
                .defaultScrollAnchor(.bottomLeading)
            }
            if let why = refused ?? unreachable {
                Text(why).font(Mono.small).foregroundStyle(Palette.asking).lineLimit(2)
            }
            keys
            input
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: target) {
            await markSeen()
            await follow()
        }
    }

    private var talkable: [BenchSessionRow] {
        PocketHome.groups(workspaces: model.workspaces, sessions: model.sessions)
            .flatMap(\.rows)
    }

    private var pills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button("‹") { dismiss() }.foregroundStyle(Palette.dim)
                ForEach(talkable) { row in
                    let on = row.screen == target
                    Button(row.title) { row.screen.map { target = $0 } }
                        .foregroundStyle(on ? Palette.text : Palette.dim)
                        .underline(on)
                }
            }
            .font(Mono.body)
        }
    }

    private var keys: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(PocketKey.allCases, id: \.self) { key in
                    Button(key.label) { send(key.input) }
                }
            }
            .font(Mono.body).foregroundStyle(Palette.dim)
            .padding(.vertical, 4)
        }
    }

    private var input: some View {
        HStack {
            TextField("", text: $message, prompt: Text("message…").foregroundStyle(Palette.faint))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit(sendMessage)
            Button("↑", action: sendMessage)
                .foregroundStyle(sending ? Palette.faint : Palette.finished)
                .disabled(sending)
        }
        .font(Mono.body)
        .foregroundStyle(Palette.text)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }

    /// The message stays in the box until benchd has taken it, or may have, so one that never
    /// left can be sent again and one that did is not.
    /// One at a time: a second tap while the first is on its way would type it into the agent twice.
    private func sendMessage() {
        let sent = message
        guard !sent.isEmpty, !sending else { return }
        sending = true
        send(.message(sent)) {
            if message == sent { message = "" }
        } after: {
            sending = false
        }
    }

    private func send(
        _ input: BenchScreenInput, then delivered: @escaping () -> Void = {},
        after answered: @escaping () -> Void = {}
    ) {
        let target = target
        Task {
            let refusal = await model.send(input, to: target)
            refused = refusal?.description
            // A send benchd may have carried out counts as sent: the box is cleared, never
            // offered a second time (it says to look at the screen instead).
            if refusal == nil || refusal?.maybeSent == true { delivered() }
            answered()
        }
    }

    /// Opening a finished turn is reading it: benchd hears it as when he focuses its pane, so it
    /// leaves the top of the agents tab.
    private func markSeen() async {
        guard let row = talkable.first(where: { $0.screen == target }),
            Attention(row) == .finished
        else { return }
        _ = await model.markSeen(harness: row.harness, session: row.id)
    }

    /// The screen ten times a second while this view is up, as `bench watch screen` reads it.
    private func follow() async {
        screen = nil
        while !Task.isCancelled {
            switch await model.screen(target) {
            case let .success(next):
                if next != screen { screen = next }
                unreachable = nil
            case let .failure(why): unreachable = why.description
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Which benchd Pocket follows.
struct ConnectView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    @Binding var url: String
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("benchd").font(Mono.title).foregroundStyle(Palette.text)
            TextField(
                "", text: $draft,
                prompt: Text("tcp://host:port").foregroundStyle(Palette.faint)
            )
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(Palette.text)
            .onSubmit(connect)
            if case let .disconnected(why) = model.state {
                Text(why).font(Mono.small).foregroundStyle(Palette.dim)
            }
            Button("connect", action: connect)
                .foregroundStyle(Palette.finished)
            Spacer()
        }
        .font(Mono.body)
        .padding(16)
        .background(Palette.sheet)
        .presentationDetents([.medium])
        .onAppear { draft = url }
    }

    /// RootView connects when the URL changes; a draft that is no URL stays here, refused.
    private func connect() {
        url = draft
        if BenchEndpoint.tcp(draft) != nil { dismiss() }
    }
}
