import SwiftUI

/// The Archon drawer's one input (#382), moved whole from the rail it used to sit in: launching
/// work, or answering the gate it has been pointed at. ⌥↑ and ⌥↓ pick the workflow a launch
/// runs; the settings button holds the rest of what a launch composes.
struct ArchonComposer: View {
    @ObservedObject var model: ArchonModel
    let workspacePath: WorkspacePath?
    let focus: FocusState<Bool>.Binding
    let isFocused: Bool

    var body: some View { composer }

    /// **One input, two jobs, and the second one says so.** Armed at a gate the field answers
    /// that gate; otherwise it launches. The launch draft is not swapped out or cleared — the
    /// binding simply points at the other string — so cancelling a gate hands back exactly the
    /// half-written instruction that was there.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let reply = model.reply { armed(reply) }
            // A vertical-axis `TextField` submits on Return and keeps ⌥Return for a newline,
            // so a one-line instruction costs one keystroke and a paragraph is still possible.
            //
            // **Shift+Enter starts a line here, and it used not to.** AppKit has no binding for
            // a shifted Return, so it resolved through the plain one and `.onSubmit` fired —
            // which in this field does not send a message, it **launches a workflow**: real
            // work, on a real branch, that somebody then has to notice and unwind. A multi-line
            // instruction is exactly when an operator reaches for the chord, and exactly when
            // the truncated half is worth most. `submitOnReturnInsertNewlineOnShift` carries
            // both halves and the whole argument (#278).
            TextField(prompt, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.textPrimary)
                .focused(focus)
                .disabled(workspacePath == nil)
                .submitOnReturnInsertNewlineOnShift(submit: submit, insertNewline: startALine)
                .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
                    guard press.modifiers == .option, model.reply == nil else { return .ignored }
                    Task {
                        await model.cycleWorkflow(
                            by: press.key == .upArrow ? -1 : 1, in: workspacePath)
                    }
                    return .handled
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.archonSurfaceRaised))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isFocused ? borderTint.opacity(0.6) : Color.archonBorder,
                            lineWidth: 1)
                )

            HStack(spacing: 6) {
                if model.reply == nil {
                    settings
                    Text(
                        model.config.workflow.isEmpty ? "no workflow chosen" : model.config.workflow
                    )
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.archonViolet)
                } else {
                    cancelReply
                }
                Spacer()
                send
            }

            if let failure = model.actionFailure ?? model.launchFailure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// While armed, the field writes `replyText`; otherwise `draft`. Two strings behind one
    /// control, which is what keeps the launch draft alive across a gate.
    private var text: Binding<String> {
        model.reply == nil ? $model.draft : $model.replyText
    }

    /// Shift+Enter's newline, into whichever of the two strings the field is writing.
    ///
    /// **It goes through `text` rather than naming `draft`, so there is one rule and not two.**
    /// Which string the field writes is `text`'s question and answering it a second time here
    /// would be a handler that could put the operator's newline into the string they are not
    /// looking at — the launch draft while they are answering a gate, or the reverse.
    ///
    /// **And it is computed here rather than handed to the modifier, which is not a style
    /// choice.** A `Binding` passed into `.onKeyPress` is captured, and the capture is a
    /// snapshot: measured on this field, `text.wrappedValue` read `""` on the same keystroke
    /// where `model.draft` read `"first line"`. Recomputed at the keystroke, `model.reply` and
    /// `model.draft` are both read off the live object. `submitOnReturnInsertNewlineOnShift`'s
    /// header has the measurement.
    private func startALine() {
        text.wrappedValue += "\n"
    }

    private var prompt: String {
        guard workspacePath != nil else { return ArchonModel.noWorkspace }
        switch model.reply?.decision {
        case .approve: return "Anything to add? (optional)"
        case .reject: return "What was wrong? This drives the rework."
        case .declared: return "Anything to add? (optional)"
        case nil: return "What should Archon do?  (⌥↑ ⌥↓ picks the workflow)"
        }
    }

    /// Whose colour the focus ring and the send button carry: the brand when launching, the
    /// decision's own tint when answering — so the field visibly belongs to the gate above it
    /// rather than looking like a launch that will go somewhere unexpected.
    private var borderTint: Color {
        model.reply.map { Self.tint(of: $0.decision) } ?? Color.archonMagenta
    }

    private static func tint(of decision: ArchonGateDecision) -> Color {
        switch decision {
        case .approve, .declared: .accent
        case .reject: .attention
        }
    }

    /// The one line that says the field has been repointed, and at what.
    private func armed(_ reply: ArchonGateReply) -> some View {
        HStack(spacing: 6) {
            Text(reply.decision.verb.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Self.tint(of: reply.decision))
            Text(reply.workflowName)
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            // The armed line gets the affordance too. It is the same id in the same place in
            // the same monospace, and an id that copies on three rows and not the fourth is
            // the inconsistency #169 was filed about rather than a saving — this is also the
            // run you are most likely to want the handle for, being the one you are about to
            // answer.
            runID(reply.runID)
        }
    }

    /// **The trailing short id, and the one thing in the rail you can take out of it.**
    ///
    /// Every run row renders eight characters of a 32-character id, so the click copies
    /// `run.id` and not what is drawn — `CopyableLabel`'s note has the argument, and
    /// `ArchonRun.shortID(of:)` is the single definition of the shortening so the label here
    /// cannot drift from the one the rows draw.
    private func runID(_ id: String) -> some View {
        CopyableLabel(value: id, hint: "Click to copy the run id — \(id)") {
            Text(ArchonRun.shortID(of: id))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.textFaint)
        }
    }

    private var cancelReply: some View {
        Button {
            model.disarm()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.chrome)
        .help("Back to launching — nothing is sent")
    }

    /// **Thin, and the second element carrying the gradient.** `.brand-bar` in the console is a
    /// solid gradient fill on a CTA; this is that at helm's scale. The label is `Color.surface`
    /// rather than white or black, because the stops are dark in the light appearance and
    /// bright in the dark one — the surface colour is the knockout that is right in both, and
    /// `PaletteTests` holds every stop to the contrast floor that makes it so.
    @ViewBuilder
    private var send: some View {
        let armed = model.reply
        // **Which "busy" this button watches depends on which job it is doing.** Launching is
        // `isLaunching`; answering is that gate's own entry in `busyRuns`, because a second
        // press during a decision is the double-approve Archon throws on.
        let busy =
            workspacePath == nil
            || (armed.map { model.busyRuns.contains($0.runID) } ?? model.isLaunching)
        Button(action: submit) {
            Text(armed?.decision.verb.uppercased() ?? "SEND")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Color.surface)
                .padding(.horizontal, 11)
                .padding(.vertical, 3.5)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 4)
                    if let armed {
                        shape.fill(Self.tint(of: armed.decision))
                    } else {
                        shape.fill(.archonBrand)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.chrome)
        .disabled(busy)
        .opacity(busy ? 0.4 : 1)
    }

    private func submit() {
        Task {
            if model.reply == nil {
                await model.launch(in: workspacePath)
            } else {
                await model.sendReply(in: workspacePath)
            }
        }
    }

    /// An icon, not a sentence — the rail renders six things, and "which workflow Enter
    /// launches" is not one of them. It is one click away instead of on screen.
    private var settings: some View {
        Button {
            Task { await model.loadWorkflows(in: workspacePath) }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11))
                .foregroundStyle(Color.textMuted)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.chrome)
        .help("What Send launches: the workflow, and how it isolates")
        .popover(isPresented: $model.isConfigOpen, arrowEdge: .bottom) { configuration }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Launch settings").font(.headline)

            Picker("Workflow", selection: $model.config.workflow) {
                if model.workflows.isEmpty {
                    Text(model.isLoadingWorkflows ? "Loading…" : "No workflows found").tag("")
                }
                ForEach(model.workflows) { workflow in
                    Text(workflow.name).tag(workflow.name)
                }
            }

            Picker("Isolation", selection: isolation) {
                ForEach(Isolation.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            if case let .branch(name) = model.config.worktree {
                TextField("Branch to create", text: branchName(current: name))
            }

            if !model.workflowLoadErrors.isEmpty {
                Text("\(model.workflowLoadErrors.count) workflow file(s) could not be loaded.")
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
            }
            HStack {
                Spacer()
                Button("Done") { model.isConfigOpen = false }
            }
        }
        .padding(16)
        .frame(width: 340)
        .foregroundStyle(Color.textPrimary)
        .background(Color.surfaceRaised)
    }

    /// The three isolation choices as one `Hashable` value a `Picker` can tag with —
    /// `WorktreeChoice.branch` carries a name, which a segment cannot.
    private enum Isolation: String, CaseIterable, Identifiable {
        case automatic, none, branch
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: "New worktree (Archon names the branch)"
            case .none: "No worktree — run on the checked-out branch"
            case .branch: "New worktree on a branch I name"
            }
        }
    }

    private var isolation: Binding<Isolation> {
        Binding(
            get: {
                switch model.config.worktree {
                case .automatic: .automatic
                case .none: .none
                case .branch: .branch
                }
            },
            set: { kind in
                switch kind {
                case .automatic: model.config.worktree = .automatic
                case .none: model.config.worktree = .none
                case .branch: model.config.worktree = .branch("")
                }
            })
    }

    private func branchName(current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { model.config.worktree = .branch($0) })
    }
}
