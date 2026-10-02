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
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            if let why = unreachable ?? model.failure {
                Text(why).font(Mono.small).foregroundStyle(Palette.asking).lineLimit(2)
            }
            keys
            input
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: target) { await follow() }
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
            Button("↑", action: sendMessage).foregroundStyle(Palette.finished)
        }
        .font(Mono.body)
        .foregroundStyle(Palette.text)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }

    private func sendMessage() {
        guard !message.isEmpty else { return }
        send(.message(message))
        message = ""
    }

    private func send(_ input: BenchScreenInput) {
        let target = target
        Task { await model.send(input, to: target) }
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
