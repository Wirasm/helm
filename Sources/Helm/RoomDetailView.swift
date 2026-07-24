import SwiftUI

/// A live room, watched and steered: open decisions pinned on top, the full room log
/// chronologically, and a composer that posts into the room as the human. Watch +
/// steer only — every action here is an existing operator REST action; helm adds no
/// logic (resolving a decision is just a `resolved[key]: …` post the engine folds).
struct RoomDetailView: View {
    let room: EngineClient.LiveRoom
    let engine: EngineClient
    /// Called after a successful post so the owner refreshes the room from the engine
    /// (read path is polling for now; this just shortens the echo).
    var onPosted: () async -> Void

    @State private var draft = ""
    @State private var sending = false
    @State private var postError: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !room.openDecisions.isEmpty {
                decisionsPinned
                Divider()
            }
            log
            Divider()
            composer
        }
    }

    // MARK: header — room name + participants with models

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(room.name).font(.title3.bold())
                if let state = room.state, state != "running" {
                    Text(state)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(room.participants, id: \.name) { p in
                    HStack(spacing: 3) {
                        Text("@\(p.name)").font(.caption.monospaced().bold())
                        if let model = p.model {
                            Text(model)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                }
            }
        }
        .padding(10)
    }

    // MARK: pinned open decisions

    private var decisionsPinned: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(room.openDecisions, id: \.key) { decision in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(decision.key)
                            .font(.headline.monospaced())
                            .foregroundStyle(.orange)
                        Text(decision.summary)
                            .font(.body)
                            .textSelection(.enabled)
                        Text("opened by \(decision.openedBy)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Resolve…") {
                        // Pre-fill only — the human completes the note and sends.
                        // The resolution is just a post; the engine owns the ledger.
                        draft = "resolved[\(decision.key)]: "
                        composerFocused = true
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
    }

    // MARK: log — chronological, system/implicit muted

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(room.log) { message in
                        logRow(message)
                            .id(message.id)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scrollToEnd(proxy, animated: false) }
            .onChange(of: room.log.count) { scrollToEnd(proxy, animated: true) }
        }
    }

    private func logRow(_ message: EngineClient.Message) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.to.isEmpty
                    ? message.from
                    : "\(message.from) → \(message.to.map { "@\($0)" }.joined(separator: ", "))")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(message.isMuted ? .tertiary : .secondary)
                Text(message.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(message.text)
                .font(message.isMuted ? .callout.italic() : .callout)
                .foregroundStyle(message.isMuted ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .opacity(message.isMuted ? 0.65 : 1)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = room.log.last else { return }
        if animated {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: composer — post into the room as the human

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let postError {
                Label(postError, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Post to the room as human — @name to address", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .disabled(sending)
                Button(action: send) {
                    if sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        postError = nil
        Task {
            do {
                try await engine.post(inRoom: room.id, text: text)
                draft = ""
                await onPosted()
            } catch let failure as EngineClient.Failure {
                // Surface the engine's own rejection text (e.g. its
                // no-such-participant message) inline, verbatim.
                postError = failure.errorDescription
            } catch {
                postError = error.localizedDescription
            }
            sending = false
        }
    }
}
