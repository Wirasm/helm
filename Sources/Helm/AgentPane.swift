import SwiftUI

/// The centre pane: one tab per agent, plus the operator's own shell.
///
/// The shell is first and always present. It is the only genuine terminal here — a PTY helm
/// spawns itself in the kild's directory — and it belongs to the operator rather than to the
/// engine. Every other tab is a *transcript*, not a terminal: the engine spawns agents with
/// pipes and talks to them over stdio, so there is no PTY to type into and no keystroke path
/// that bypasses the message log.
///
/// That absence removes a bug rather than a feature. If keystrokes could reach an agent
/// directly, the agent would start working while `idle` stayed set — the engine clears
/// `idle` only on a delivered turn — and both the attention model and the message log would
/// drift from reality, silently.
struct AgentPane: View {
    let kild: Kild
    @Binding var selectedTab: TabID
    /// Lines for the selected agent, resolved by the caller from the right source.
    let lines: [Conversation.Line]
    let isLoading: Bool
    let error: String?
    /// Compose target. Sending is always addressed — the engine never infers a recipient.
    let send: (String) -> Void

    enum TabID: Hashable {
        case shell
        case agent(String)
    }

    private var selectedAgent: Agent? {
        guard case let .agent(handle) = selectedTab else { return nil }
        return kild.agents.first { $0.handle == handle }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(kild: kild, selected: $selectedTab)
            Divider()

            if let agent = selectedAgent {
                // `.id(agent.handle)` on both is load-bearing, not hygiene. Without it these
                // occupy the same structural position across an agent switch, so SwiftUI
                // reuses the view — and `Composer`'s @State draft survives. Type a message
                // for @alice, click @bob's tab, press enter: it goes to @bob. Deterministic
                // misdirection of a message to the wrong agent.
                TranscriptBody(
                    agent: agent, lines: lines, isLoading: isLoading, error: error
                )
                .id(agent.handle)
                Divider()
                Composer(handle: agent.handle, send: send)
                    .id(agent.handle)
            } else {
                // The shell tab hosts a real terminal, owned by TerminalManager. Left as a
                // seam rather than reimplemented: that plumbing survives the rename untouched
                // and has nothing to do with the agent model.
                ShellPlaceholder(kild: kild)
            }
        }
    }
}

// MARK: - Tabs

private struct TabStrip: View {
    let kild: Kild
    @Binding var selected: AgentPane.TabID

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                Tab(
                    label: "⌂ shell", isSelected: selected == .shell, italic: false,
                    waiting: false
                ) { selected = .shell }

                ForEach(kild.agents) { agent in
                    Tab(
                        label: "@\(agent.handle)",
                        isSelected: selected == .agent(agent.handle),
                        // Italic marks an attached agent. The one styling that reads a
                        // field's value, and justified because it marks how much is
                        // observable rather than what the agent is for.
                        italic: agent.ownership == .attached,
                        waiting: agent.isWaiting
                    ) { selected = .agent(agent.handle) }
                }
            }
        }
        .frame(height: 30)
    }
}

private struct Tab: View {
    let label: String
    let isSelected: Bool
    let italic: Bool
    let waiting: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Text(label).italic(italic)
                // Tabs carry `idle` too, so attention is visible whichever surface you are
                // looking at — the sidebar dot and this are the same field.
                if waiting { AttentionDot(waiting: true) }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 11)
            .frame(maxHeight: .infinity)
            .background(isSelected ? Color.primary.opacity(0.06) : .clear)
            .overlay(alignment: .bottom) {
                if isSelected { Rectangle().fill(Color.accentColor).frame(height: 2) }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Body

private struct TranscriptBody: View {
    let agent: Agent
    let lines: [Conversation.Line]
    let isLoading: Bool
    let error: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    Header(agent: agent)

                    if let error {
                        // The engine's own words. For an attached agent this is usually
                        // "has no pi session file", which is not a failure to retry — it is
                        // the correct answer to a question helm should not have asked.
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
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `initial: true` because `.id(agent.handle)` makes every tab switch a first
            // appearance. The two-parameter form defaults to `initial: false` and fires only
            // on a subsequent change — so switching to an already-loaded transcript had
            // nothing to fire on and landed at the TOP, which is the wrong end of a
            // conversation. Pinning identity per agent fixed the draft leak and broke this;
            // both are wanted.
            .onChange(of: lines.count, initial: true) { _, _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

private struct Header: View {
    let agent: Agent

    var body: some View {
        // Every value here is a field. `persona` is rendered as the opaque string it is —
        // never styled by value, never given an icon, because the engine does not interpret
        // it and the moment helm does, PRP has leaked into the cockpit.
        Text(parts.joined(separator: " · "))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
    }

    private var parts: [String] {
        var parts = [agent.ownership.rawValue]
        if let persona = agent.persona { parts.append(persona) }
        if let model = agent.model { parts.append(model) }
        if let tokens = agent.tokens { parts.append("\(tokens / 1000)k tok") }
        if let cost = agent.cost { parts.append(String(format: "$%.2f", cost)) }
        if agent.isStopped {
            parts.append("stopped")
        } else if agent.isIdle {
            parts.append("idle")
        }
        return parts
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
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(role == "user" ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            }
        case let .message(from, to, text, _):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    // A stable accent per handle, so a sender keeps its colour across
                    // refreshes and launches. `human` gets the app accent instead: an
                    // unattributed message is usually the operator's own shell, and it
                    // should not look like just another agent.
                    Text("@\(from)")
                        .foregroundStyle(
                            SenderStyle.isHuman(from)
                                ? Color.accentColor : SenderStyle.accent(for: from))
                    Text(" → \(to.map { "@\($0)" }.joined(separator: ", "))")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 10, design: .monospaced))
                Text(text).font(.system(size: 12)).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Composing

/// The one way in.
///
/// Posts `POST …/messages` with `to[]`. There is no unlogged path to an agent, because there
/// is no PTY to type into — so every instruction an agent receives is in the log, attributed.
private struct Composer: View {
    let handle: String
    let send: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 7) {
            Text("→ @\(handle)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tint)
            TextField("send a message", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .onSubmit(submit)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(text)
        draft = ""
    }
}

private struct ShellPlaceholder: View {
    let kild: Kild

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("⌂ shell").font(.system(size: 12, design: .monospaced))
            Text(kild.git?.path ?? kild.cwd)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
