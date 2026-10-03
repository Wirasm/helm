import HelmWire
import PocketKit
import SwiftUI

/// A waiting prompt's question and its choices as buttons, each typing the key that picks it. A
/// pick takes the bar away at once; the next read of the screen brings it back if the agent
/// still asks.
struct ChoicesBar: View {
    @EnvironmentObject private var model: PocketModel
    @Binding var shown: PromptChoices?
    let prompt: PromptChoices
    let target: String
    @State private var refused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let question = prompt.question {
                Text(question).font(Mono.small).foregroundStyle(Palette.asking)
            }
            ForEach(prompt.choices, id: \.keys) { choice in
                Button {
                    send(choice.keys)
                } label: {
                    Text("\(choice.keys)  \(choice.label)").lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Mono.body).foregroundStyle(Palette.text)
            }
            if prompt.canEscape {
                Button("esc  cancel") { send("\u{1b}") }
                    .font(Mono.body).foregroundStyle(Palette.dim)
            }
            if let refused { Text(refused).font(Mono.small).foregroundStyle(Palette.asking) }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }

    private func send(_ keys: String) {
        Task {
            let refusal = await model.send(.keys(keys), to: target)
            refused = refusal?.description
            if refusal == nil { shown = nil }
        }
    }
}

/// The message field: multi-line, the keyboard up when the chat opens, its draft kept per chat.
/// Send types it into the agent and presses Return (`screen/send`); one at a time, and a message
/// benchd may have taken is cleared rather than offered twice.
struct Composer: View {
    @EnvironmentObject private var model: PocketModel
    @EnvironmentObject private var memory: ChatMemory
    let chat: String
    let target: String?
    @State private var draft = ""
    @State private var sending = false
    @State private var refused: String?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let refused { Text(refused).font(Mono.small).foregroundStyle(Palette.asking) }
            HStack(alignment: .bottom) {
                TextField(
                    "", text: $draft, prompt: Text("message…").foregroundStyle(Palette.faint),
                    axis: .vertical
                )
                .lineLimit(1...6)
                .focused($typing)
                Button("↑", action: send)
                    .foregroundStyle(sending || target == nil ? Palette.faint : Palette.finished)
                    .disabled(sending || target == nil)
            }
            .font(Mono.body)
            .foregroundStyle(Palette.text)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
        .onAppear(perform: open)
        .onChange(of: draft) { memory.keep(draft, for: chat) }
    }

    private func open() {
        draft = memory.draft(chat)
        refused = nil
        typing = true
    }

    private func send() {
        let text = draft
        guard let target, !text.isEmpty, !sending else { return }
        sending = true
        Task {
            let refusal = await model.send(.message(text), to: target)
            refused = refusal?.description
            // Gone, or maybe gone: off this chat's draft, even if he has moved to another chat
            // meanwhile, so it is never offered to send twice.
            if refusal == nil || refusal?.maybeSent == true {
                if memory.draft(chat) == text { memory.keep("", for: chat) }
                if draft == text { draft = "" }
            }
            sending = false
        }
    }
}

/// The quick switcher: the chats list, searchable, a tap opening that chat in place.
struct SwitcherView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    let open: (String) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $query, prompt: Text("search").foregroundStyle(Palette.faint))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(Mono.body).foregroundStyle(Palette.text)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(
                        PocketHome.sections(
                            workspaces: model.workspaces, sessions: model.sessions, query: query)
                    ) { section in
                        Text(section.name.uppercased()).tracking(1)
                            .font(Mono.group).foregroundStyle(Palette.dim).padding(.top, 8)
                        ForEach(section.running) { row in
                            ChatRowView(row: row).onTapGesture {
                                open(row.id)
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Palette.sheet)
        .presentationDetents([.large])
    }
}
