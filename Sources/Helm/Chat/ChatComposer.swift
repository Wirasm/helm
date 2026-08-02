import SwiftUI

/// Send a message to the agent without leaving the reading face.
///
/// **Why this is safe here when the spike's client half was not.** That half
/// died because prose typed into a live permission prompt is *silently
/// destructive* — `yes go ahead that is fine` had its `y` approve and run a
/// network command, later characters toggled the session into manual mode, and
/// the sentence was never delivered. The spike had no signal to guard it:
/// `mouse_captured` was a false negative on Claude Code's trust prompt, a
/// constant across the whole REPL session, and sticky after the TUI died. Only
/// content sniffing worked, and it failed *open*.
///
/// The registry's `status` is the signal that did not exist then: a typed field,
/// per-pid, seconds-fresh. A box that submits **only when the agent is idle**
/// cannot reach the destructive case at all, because that case is by definition
/// mid-turn. The guard fails closed.
///
/// **Not in scope, by construction: answering a waiting agent.** `waiting` is
/// exactly the permission-prompt case, so it is refused here rather than guessed
/// at — and the terminal face is one keystroke away, which is never wrong.
struct ChatComposer: View {
    @ObservedObject var model: ChatModel
    /// Handed the finished message. The view owns no pty knowledge.
    let send: (String) -> Void
    /// Text offered by something else — a canvas's `Post`. Consumed once and cleared, so
    /// a re-render cannot re-seed a field the operator has since edited.
    ///
    /// **It fills the field and nothing more.** Typing was always allowed here; only
    /// sending is gated, and that gate is `ChatModel.canSend` — `status == .idle`, with a
    /// measured reason (#29) not to loosen it. Offering text is exactly as safe as the
    /// operator typing it.
    @Binding var prefill: String?

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // **Typing is always allowed; only sending is gated.** Composing a
            // reply while the agent finishes is the normal case, and a box that
            // cannot be typed into until the agent stops would lose the sentence
            // you had in your head. The safety property is on submission, and it
            // is enforced in `submit` as well as on the button — the field being
            // live is not a second route around the gate.
            TextField(prompt, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: 13))
                .foregroundStyle(Color.textPrimary)
                .focused($focused)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSubmit ? Color.accent : Color.textMuted.opacity(0.4))
            .disabled(!canSubmit)
            .help(prompt)
        }
        .onChange(of: prefill) { _, offered in
            guard let offered else { return }
            draft = draft.isEmpty ? offered : draft + "\n\n" + offered
            prefill = nil
            focused = true
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    focused && model.canSend
                        ? Color.accent.opacity(0.55) : Color.border,
                    lineWidth: 1)
        )
        // The draft is kept, not cleared, when the gate closes: the agent going
        // busy mid-sentence must not cost the operator what they had typed.
        .animation(.easeOut(duration: 0.2), value: model.canSend)
    }

    private var canSubmit: Bool {
        model.canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The box says why it is shut, always. A disabled control with no reason is
    /// the same lie as an advisory banner that is wrong half the time.
    private var prompt: String {
        guard let status = model.status else {
            return "No agent is running in this terminal"
        }
        switch status {
        case .idle: return "Message the agent"
        case .busy: return "The agent is working — it can be messaged when it stops"
        case .waiting:
            return "The agent is waiting on a prompt — answer it in the terminal (⌘T)"
        case .shell: return "A command is running — it can be messaged when it stops"
        }
    }

    private func submit() {
        guard canSubmit else { return }
        send(draft)
        draft = ""
    }
}
