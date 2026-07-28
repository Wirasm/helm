import SwiftUI

/// One agent's conversation, in the dock.
///
/// **Not the centre pane rev 5 drew, and deliberately so.** That design put one shell plus
/// one tab per agent in the middle of the window — but `TerminalManager` groups terminals by
/// *workspace folder*, and rev 5's centre groups by *kild*. Those are different models, and
/// reconciling them means deciding whether a terminal belongs to a folder or to a kild's
/// worktree. That is a design decision with an operator in it, not a wiring task, so it is
/// not one to settle by guessing while nobody is watching.
///
/// The dock is already the detail surface, and it makes the conversation reachable today
/// without pre-empting that choice. If the centre is later restructured, this view moves;
/// nothing about it assumes where it lives.
struct AgentConversation: View {
    let kild: Kild
    let agent: Agent
    let lines: [Conversation.Line]
    let isLoading: Bool
    let error: String?
    let close: () -> Void
    let send: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            Composer(handle: agent.handle, send: send)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: close) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Back to \(kild.name)")

            Text("@\(agent.handle)")
                .font(.system(size: 12, weight: .semibold))
                // Italic marks an attached agent — the one styling that reads a field's
                // value, justified because it marks how much is observable rather than what
                // the agent is for.
                .italic(agent.ownership == .attached)

            Spacer(minLength: 4)

            if agent.isStopped {
                Text("stopped").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else if agent.isWaiting {
                AttentionDot(waiting: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    if let error {
                        // The engine's own words. For an attached agent this is usually
                        // "has no pi session file" — not a failure to retry, but the correct
                        // answer to a question helm should not have asked.
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    } else if lines.isEmpty && !isLoading {
                        Text(Conversation.emptyExplanation(for: agent))
                            .font(.system(size: 11))
                            .italic()
                            .foregroundStyle(.tertiary)
                    }

                    ForEach(lines) { LineView(line: $0) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `initial: true` because this view is `.id`-pinned per agent, so every open is
            // a first appearance. The two-parameter form defaults to false and fires only on
            // a later change — which would land you at the top of a conversation.
            .onChange(of: lines.count, initial: true) { _, _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// Every value here is a field. `persona` is the opaque string the engine stores and
    /// never interprets, so helm renders it and does no more.
    private var subtitle: String {
        var parts = [agent.ownership.rawValue]
        if let persona = agent.persona { parts.append(persona) }
        if let model = agent.model { parts.append(KildPresentation.modelShortname(model)) }
        if let tokens = agent.tokens { parts.append("\(tokens / 1000)k tok") }
        if let cost = agent.cost { parts.append(String(format: "$%.2f", cost)) }
        return parts.joined(separator: " · ")
    }
}

private struct LineView: View {
    let line: Conversation.Line

    var body: some View {
        switch line {
        case let .turn(_, role, text, toolCalls):
            VStack(alignment: .leading, spacing: 2) {
                if !toolCalls.isEmpty {
                    Text(toolCalls.map { "▸ \($0)" }.joined(separator: "  "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(role == "user" ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            }
        case let .message(from, to, text, _):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text("@\(from)")
                        .foregroundStyle(
                            SenderStyle.isHuman(from)
                                ? Color.accentColor : SenderStyle.accent(for: from))
                    Text(" → \(to.map { "@\($0)" }.joined(separator: ", "))")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 10, design: .monospaced))
                Text(text).font(.system(size: 11.5)).textSelection(.enabled)
            }
        }
    }
}

/// The one way in.
///
/// Posts to the message log with an explicit recipient. There is no unlogged path to an
/// agent — the engine spawns them with pipes, so there is no PTY to type into — which means
/// every instruction an agent receives is on the record and attributed.
private struct Composer: View {
    let handle: String
    let send: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 7) {
            Text("→ @\(handle)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tint)
            TextField("send a message", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .onSubmit(submit)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(text)
        draft = ""
    }
}
