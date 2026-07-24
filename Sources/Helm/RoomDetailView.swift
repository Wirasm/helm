import SwiftUI

/// A live room, watched and steered: open decisions pinned on top, the full room log
/// chronologically, and a composer that posts into the room as the human. Watch +
/// steer only — every action here is an existing operator REST action; helm adds no
/// logic (resolving a decision is just a `resolved[key]: …` post the engine folds).
///
/// Archived rooms reuse this view with `readOnly`: the composer becomes an archived
/// banner, the decision ledger shows resolutions, and each participant chip offers
/// its pi resume command (safe only for dead sessions — never `--session` a live one).
struct RoomDetailView: View {
    let room: EngineClient.LiveRoom
    let engine: EngineClient
    /// Archived (closed/halted) room: no composer, no resolve — watch only.
    var readOnly = false
    /// Called after a successful post so the owner refreshes the room from the engine
    /// (read path is polling for now; this just shortens the echo).
    var onPosted: () async -> Void

    @State private var draft = ""
    @State private var sending = false
    @State private var postError: String?
    @State private var copiedRoomID = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !shownDecisions.isEmpty {
                decisionsPinned
                Divider()
            }
            log
            Divider()
            if readOnly {
                archivedBanner
            } else {
                composer
            }
        }
    }

    /// Live: only what needs the human now. Archived: the full ledger — what was
    /// asked AND how it was resolved is the point of reading history.
    private var shownDecisions: [EngineClient.Decision] {
        readOnly ? (room.decisions ?? []) : room.openDecisions
    }

    // MARK: header — room name + participants with models

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(room.name).font(.title3.bold())
                roomIDBadge
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
                        // Same accent as the participant's log rows — the chips
                        // double as the color legend.
                        Text("@\(p.name)")
                            .font(.caption.monospaced().bold())
                            .foregroundStyle(
                                SenderStyle.isHuman(p.name)
                                    ? Color.accentColor
                                    : SenderStyle.accent(for: p.name)
                            )
                        if let model = p.model {
                            Text(model)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .contextMenu {
                        // Resume only for archived rooms — the session is dead, so
                        // `pi --session` has one writer. (Live would need --fork.)
                        if readOnly, let resume = p.resumeCommand {
                            Button("Copy resume command") { Pasteboard.copy(resume) }
                        }
                    }
                    .help(
                        readOnly && p.resumeCommand != nil
                            ? "Right-click to copy: \(p.resumeCommand!)"
                            : ""
                    )
                }
            }
        }
        .padding(10)
    }

    /// Short room id, click-to-copy (copies the FULL id). The brief "copied"
    /// swap is per-room state — the view is re-identified per room by the owner.
    private var roomIDBadge: some View {
        Button {
            Pasteboard.copy(room.id)
            copiedRoomID = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copiedRoomID = false
            }
        } label: {
            HStack(spacing: 3) {
                Text(copiedRoomID ? "copied" : String(room.id.prefix(8)))
                    .font(.caption.monospaced())
                Image(systemName: copiedRoomID ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
            }
            .foregroundStyle(copiedRoomID ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help("Copy room id: \(room.id)")
    }

    // MARK: pinned open decisions

    private var decisionsPinned: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(shownDecisions, id: \.key) { decision in
                let resolved = decision.resolvedAt != nil
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: resolved ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(resolved ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(decision.key)
                            .font(.headline.monospaced())
                            .foregroundStyle(resolved ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        Text(decision.summary)
                            .font(.body)
                            .textSelection(.enabled)
                        if resolved, let note = decision.note {
                            Text(note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text(attribution(of: decision, resolved: resolved))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !readOnly {
                        Button("Resolve…") {
                            // Pre-fill only — the human completes the note and sends.
                            // The resolution is just a post; the engine owns the ledger.
                            draft = "resolved[\(decision.key)]: "
                            composerFocused = true
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Orange only while something is actually open (an archived ledger may be
        // fully resolved — no alarm color for settled history).
        .background(.orange.opacity(room.openDecisions.isEmpty ? 0 : 0.08))
    }

    private func attribution(of decision: EngineClient.Decision, resolved: Bool) -> String {
        guard resolved else { return "opened by \(decision.openedBy)" }
        let resolver = decision.resolvedBy.map { " by \($0)" } ?? ""
        return "opened by \(decision.openedBy) · resolved\(resolver)"
    }

    // MARK: log — chronological, system/implicit muted

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Rows carry their own bubble padding now — keep the stack tight
                // so the log stays an operator console, not a chat app.
                LazyVStack(alignment: .leading, spacing: 6) {
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

    /// Three visual tiers, so the log reads without parsing header lines:
    /// human posts (accent bubble, trailing), agent posts (neutral bubble, leading,
    /// sender-colored name + edge bar, tinted when addressed to the human), and
    /// system/implicit noise (no bubble, quieter than everything else).
    @ViewBuilder
    private func logRow(_ message: EngineClient.Message) -> some View {
        if message.isMuted {
            mutedRow(message)
        } else if SenderStyle.isHuman(message.from) {
            humanRow(message)
        } else {
            agentRow(message)
        }
    }

    /// The human's own posts: chat-style, trailing-aligned, accent-tinted.
    private func humanRow(_ message: EngineClient.Message) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.from)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(Color.accentColor)
                if !message.to.isEmpty {
                    Text("→ " + recipients(of: message))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                timestamp(message)
            }
            Text(message.text)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Agent posts: leading-aligned, neutral bubble, the sender's stable accent on
    /// the name and a leading edge bar. Posts addressed to the human (reports) get
    /// the bubble tinted in the sender's accent — a notch louder than agent↔agent.
    private func agentRow(_ message: EngineClient.Message) -> some View {
        let accent = SenderStyle.accent(for: message.from)
        let toHuman = message.to.contains(where: SenderStyle.isHuman)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.from)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(accent)
                if !message.to.isEmpty {
                    Text("→ " + recipients(of: message))
                        .font(.caption.monospaced())
                        .fontWeight(toHuman ? .semibold : .regular)
                        .foregroundStyle(toHuman ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                timestamp(message)
            }
            Text(message.text)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            toHuman ? AnyShapeStyle(accent.opacity(0.10)) : AnyShapeStyle(.quinary),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Engine notices + auto-posted turn replies: no bubble, quieter than any post.
    private func mutedRow(_ message: EngineClient.Message) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(message.to.isEmpty
                    ? message.from
                    : "\(message.from) → \(recipients(of: message))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                timestamp(message)
            }
            Text(message.text)
                .font(.caption.italic())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recipients(of message: EngineClient.Message) -> String {
        message.to.map { "@\($0)" }.joined(separator: ", ")
    }

    private func timestamp(_ message: EngineClient.Message) -> some View {
        Text(message.date.formatted(date: .omitted, time: .shortened))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = room.log.last else { return }
        if animated {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: archived banner — shown in place of the composer for read-only rooms

    private var archivedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "archivebox")
            Text("\(room.state ?? "closed") — archived · read-only")
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(10)
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
