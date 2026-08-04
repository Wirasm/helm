import SwiftUI

/// The chat face: a readable view of the agent's turn, drawn over the terminal
/// pane it shares.
///
/// **The same pane, two faces.** The terminal is the normal one; the strip's
/// button (or ⌘T) swaps this one over the top of it. The pty underneath keeps
/// running and its view stays mounted — one attached surface drives the ghostty
/// runtime for every surface on it, so unmounting the only one would stall them
/// all.
///
/// **What it shows:** the agent's prose with the turn's last word set apart, and
/// the operator's own turns. Not tool calls, not tool results, not thinking —
/// not collapsed or greyed, absent. Tool activity exists here only as motion in
/// `ChatTicker`, which says *still working* without saying what it is working on.
///
/// **What it reads:** the transcript on disk, and one field — the registry's
/// `status`. Nothing reads the terminal surface. When the transcript goes quiet
/// the tape simply keeps running; a blocked agent's question lives in the
/// terminal face, one keystroke away.
struct ChatOverlay: View {
    @ObservedObject var session: TerminalSession
    /// Whether this pane is the bench's focused one. Carried down to the composer and used for
    /// nothing else here: the face that is being *read* wants the keyboard in its text field,
    /// and with two chat faces open at once only one of them may claim it.
    let holdsKeyboard: Bool
    @StateObject private var model = ChatModel()
    /// Text a canvas's `Post` offered this pane, waiting to be dropped into the composer.
    ///
    /// **Filtered by pane.** A `ComposeRequest` names the pane the workbench chose, and a
    /// terminal pane's id is its session id — so this is how one Post reaches one composer
    /// rather than every open chat face. The workbench makes the choice; this obeys it.
    @State private var prefill: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.surface
            column

            // Prose runs to both edges of the pane while it scrolls. The scrims
            // let it arrive and leave instead of being sliced through a line of
            // type, and give the ticker something to sit on.
            VStack(spacing: 0) {
                scrim(.top).frame(height: 44)
                Spacer(minLength: 0)
                scrim(.bottom).frame(height: model.isWorking ? 150 : 118)
            }
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.32), value: model.isWorking)

            footer
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmComposeText)) { note in
            guard let request = note.object as? ComposeRequest, request.pane == session.id
            else { return }
            prefill = request.text
        }
        .task {
            // The pid is read fresh each tick rather than captured: the
            // foreground process of a pty moves constantly — `shell` was measured
            // at 947 consecutive samples — and the agent we are reading can exit
            // and be replaced without this view ever being rebuilt.
            await model.run(pid: { session.hostView.foregroundPid })
        }
    }

    // MARK: - The conversation

    @ViewBuilder
    private var column: some View {
        if model.entries.isEmpty {
            empty
        } else {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        // Bottom-aligned inside a container-height frame: two
                        // paragraphs into a session the prose sits down by the
                        // ticker instead of stranding itself under a screenful of
                        // nothing. Longer than the pane, it grows normally.
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer(minLength: 0)
                            blocks
                        }
                        // ~68 characters at the answer's size. The whole point of
                        // this face is that it reads better than a terminal, and a
                        // full-width line does not.
                        .frame(maxWidth: 620, alignment: .leading)
                        .padding(.horizontal, 44)
                        .padding(.top, 56)
                        .padding(.bottom, 132)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                    // New prose anchors to its OWN TOP. Blocks land whole and can
                    // be 51 KB — measured max — so pinning the bottom would throw
                    // the reader past all of it. The ScrollView clamps at the
                    // content end, so a short block still settles at the bottom.
                    .onChange(of: model.entries.last?.id) { _, id in
                        scroll(proxy, to: id, animated: true)
                    }
                    .onAppear { scroll(proxy, to: model.entries.last?.id, animated: false) }
                }
            }
        }
    }

    /// Deferred a runloop, then again after layout: the first pass runs before
    /// the new block has been measured, so on a big arrival it lands short. The
    /// second is the one that is right, and the one the reader sees move.
    private func scroll(_ proxy: ScrollViewProxy, to id: Int?, animated: Bool) {
        guard let id else { return }
        Task { @MainActor in
            proxy.scrollTo(id, anchor: .top)
            try? await Task.sleep(for: .milliseconds(150))
            if animated {
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(id, anchor: .top) }
            } else {
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private var blocks: some View {
        let items = Array(model.window)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ChatBlock(
                    entry: item,
                    isAnswer: model.answers.contains(item.id),
                    space: space(at: index, in: items)
                )
                .id(item.id)
            }
        }
    }

    /// A beat between blocks of one turn, a longer one where a turn ended. With
    /// the operator's own turns rendered, the gap is no longer the only record of
    /// them — but it is still what separates one exchange from the next.
    private func space(at index: Int, in items: [ChatEntry]) -> CGFloat {
        guard index > 0 else { return 0 }
        return items[index - 1].turn == items[index].turn ? 24 : 54
    }

    // MARK: - The footer

    /// The composer, and the ticker above it while the agent works.
    ///
    /// The ticker's animation lives on this subtree and nowhere above it. Put it
    /// on the ZStack and it reaches the prose too, where the same flag swaps the
    /// answer's type scale — and SwiftUI interpolates between the two scales,
    /// reflowing every line of the block for a third of a second. A paragraph
    /// visibly scrambling at the moment you are meant to start reading it is the
    /// least calm thing this view could do.
    private var footer: some View {
        VStack(spacing: 12) {
            if model.isWorking {
                ChatTicker(beats: model.beats, since: model.workingSince)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            ChatComposer(
                model: model, send: send, prefill: $prefill, holdsKeyboard: holdsKeyboard
            )
            .frame(maxWidth: 620)
            maskNotice
        }
        .padding(.horizontal, 44)
        .padding(.bottom, 16)
        .animation(.easeOut(duration: 0.32), value: model.isWorking)
    }

    /// A silent mask is its own lie, so the count is on screen whenever it has
    /// fired. It also states the limit: this catches shapes, not secrets.
    @ViewBuilder
    private var maskNotice: some View {
        if model.maskedCount > 0 {
            Text(
                "\(model.maskedCount) credential\(model.maskedCount == 1 ? "" : "s") masked "
                    + "· best-effort, a shapeless secret still gets through"
            )
            .font(.system(size: 10))
            .foregroundStyle(Color.textMuted)
        }
    }

    // MARK: - Empty

    /// **The toggle is always pressable, so this pane must always say why.** An
    /// empty page here is the failure the spike's reader called out: a miss and a
    /// silence look identical, and only one of them is worth telling anyone about.
    private var empty: some View {
        VStack(spacing: 9) {
            Text(model.isWorking ? "Working" : "Nothing to read yet")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Text(reason)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 96)
    }

    private var reason: String {
        switch model.source {
        case .searching: return "Looking for an agent in this terminal."
        case .unavailable(let why): return why
        case .reading: return "The agent has not written any prose in this session."
        }
    }

    // MARK: - Writing

    /// The composer's one effect. `performBindingAction` is public on
    /// `AppTerminalView`, so this costs no vendor patch — see `PtyText` for the
    /// route and the escaping.
    private func send(_ message: String) {
        guard let action = PtyText.submitAction(for: message) else { return }
        session.hostView.performBindingAction(action)
    }

    /// Paper fading to nothing; `solid` is the edge the paper is opaque at. The
    /// middle stop holds it nearly solid for the first stretch, so the band the
    /// ticker and composer sit in is clear rather than half-legible.
    private func scrim(_ solid: UnitPoint) -> some View {
        LinearGradient(
            stops: [
                .init(color: Color.surface, location: 0),
                .init(color: Color.surface.opacity(0.94), location: 0.45),
                .init(color: Color.surface.opacity(0), location: 1),
            ],
            startPoint: solid, endPoint: solid == .top ? .bottom : .top)
    }
}

// MARK: - One block

/// Three treatments, one voice. What the operator said carries a rail; what the
/// agent said along the way sits a step back; the turn's last word gets the air,
/// the full ink, and a rule.
private struct ChatBlock: View {
    let entry: ChatEntry
    let isAnswer: Bool
    /// Space above this block.
    let space: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isAnswer {
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accent).frame(width: 34, height: 1)
                    Rectangle().fill(Color.border).frame(height: 1)
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            content
        }
        .padding(.top, space)
        // DELIBERATELY UNANIMATED. Interpolating between the two type scales
        // reflows every line of the block for a third of a second. The turn
        // ending is animated where it belongs — the ticker fading.
    }

    @ViewBuilder
    private var content: some View {
        switch entry.voice {
        case .operatorTurn:
            // A rail, not a bubble and not a different size. The operator's words
            // are context for reading the answer, not the thing being read.
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.accent.opacity(0.45))
                    .frame(width: 2)
                MarkdownText(text: entry.text, theme: .chatOperator)
                    .foregroundStyle(Color.textMuted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("You said")
        case .agent:
            MarkdownText(text: entry.text, theme: isAnswer ? .chatAnswer : .chatAside)
                .foregroundStyle(isAnswer ? Color.textPrimary : Color.textMuted)
        }
    }
}
