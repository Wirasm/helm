import SwiftUI

/// The rail, reduced to what the operator kept.
///
/// **Six things render, top to bottom, and nothing else**: the Archon title, the field you type
/// in, the button that sends it, one line per gated run carrying that gate's question and its
/// two verbs, one line per running run with a subline naming the stage it is on, and one line
/// per finished run you have not cleared. No headers, no hints, no empty-state prose, no
/// footers, no liveness word. The version this replaces had all of them and the verdict was
/// *"too much bloat"*.
///
/// The count-per-status line is gone and is now a row per run, because a count is the one thing
/// here that could not be acted on — and, under `scopeFallback`, could be wrong by two orders
/// of magnitude with nothing on screen to say so.
///
/// **The gate line is the sixth and it is the only row with controls**, because it is the only
/// row where the run is blocked on the person reading it. Everything else the rail shows is
/// something to look at; this is something to answer.
///
/// **The brand is the duotone, not a magenta.** Archon's console says so itself — *"the duotone
/// magenta → violet → teal gradient drawn from the shield logo is THE brand"* — and defines two
/// utilities for exactly the two elements here: `.brand-text` paints a wordmark's glyphs with
/// it, `.brand-bar` fills a CTA with it. So the title and the send button carry the same
/// three-stop `LinearGradient`, and everything else is helm's palette.
///
/// **Status colour is deliberately NOT brand.** The console keeps the two apart so a brand
/// swap cannot break meaning, and helm honours the split: a running run's mark is electric
/// blue, a failed count is red, a completed one is the brand teal because `--success` points
/// there. Painting the whole rail magenta would be the easy version of "looks like Archon" and
/// the wrong one.
struct ArchonRailView: View {
    @ObservedObject var model: ArchonRailModel
    let workspacePath: WorkspacePath?

    @FocusState private var composerFocused: Bool
    /// The finished row under the pointer, so only that row shows its dismiss control. The rule
    /// lives in `ArchonRowReveal` rather than in the `.onHover` closure — see #180.
    @State private var reveal = ArchonRowReveal()

    var body: some View {
        VStack(spacing: 0) {
            title
            Color.border.frame(height: 1)
            composer
            Color.border.frame(height: 1)
            content
            Color.border.frame(height: 1)
            WorktreesRailView(model: model.worktrees, workspacePath: workspacePath)
        }
        .frame(width: 300)
        .background(ChromeBackground())
        // Keyed on the workspace: switching one cancels the poll and starts a poll about the
        // new one. Without the id the loop would keep asking Archon about the folder helm was
        // showing when the rail opened.
        .task(id: workspacePath) { await model.poll(in: workspacePath) }
    }

    // MARK: - Identity

    /// Thin, and gradient-painted. The mark is the whole of Archon's shield that survives at
    /// 7 points, and it carries the same gradient as the word beside it so the two read as one
    /// logotype rather than as an icon plus a label.
    private var title: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .frame(width: 7, height: 7)
                .rotationEffect(.degrees(45))
            Text("ARCHON")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(1.8)
            Spacer()
        }
        .foregroundStyle(.archonBrand)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Input

    /// **One input, two jobs, and the second one says so.** Armed at a gate the field answers
    /// that gate; otherwise it launches. The launch draft is not swapped out or cleared — the
    /// binding simply points at the other string — so cancelling a gate hands back exactly the
    /// half-written instruction that was there.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let reply = model.reply { armed(reply) }
            // The same field shape as the chat composer, for the same reason: a vertical-axis
            // `TextField` submits on Return and keeps ⌥Return for a newline, so a one-line
            // instruction costs one keystroke and a paragraph is still possible.
            TextField(prompt, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.textPrimary)
                .focused($composerFocused)
                .disabled(workspacePath == nil)
                .onSubmit { submit() }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.surfaceRaised))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            composerFocused ? borderTint.opacity(0.6) : Color.border,
                            lineWidth: 1)
                )

            HStack(spacing: 6) {
                if model.reply == nil { settings } else { cancelReply }
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

    private var prompt: String {
        guard workspacePath != nil else { return ArchonRailModel.noWorkspace }
        switch model.reply?.decision {
        case .approve: return "Anything to add? (optional)"
        case .reject: return "What was wrong? This drives the rework."
        case nil: return "What should Archon do?"
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
        case .approve: .accent
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    // MARK: - What is happening

    /// Three lists in one column, ordered by who is waiting on whom: **gates first**, because a
    /// gate is the only thing here blocked on the operator; then the live work, which is
    /// blocked on nothing; then what has finished, which is news.
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.gated, id: \.id) { run in
                    gatedLine(run)
                }
                if !model.gated.isEmpty, !model.running.isEmpty || !model.finished.isEmpty {
                    Color.border.frame(height: 1).padding(.vertical, 6)
                }
                ForEach(model.running, id: \.id) { run in
                    runningLine(run)
                }
                if !model.running.isEmpty, !model.finished.isEmpty {
                    Color.border.frame(height: 1).padding(.vertical, 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(model.finished, id: \.id) { run in
                        finishedLine(run)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    /// A paused run, and the gate holding it.
    ///
    /// **The subline is the gate's own question**, which Archon writes into the run's metadata
    /// at the pause — not the node id the running line shows. A running run's subline answers
    /// *where is it*; this one has to answer *what is being asked of me*, and only one of those
    /// is worth a click.
    ///
    /// **Verbs appear only when the gate is genuinely the operator's**, which is a fact read
    /// from Archon rather than a guard: a gate already resolved, or one belonging to a
    /// `workflow:` sub-run, is answered by a call Archon throws on. The row says why instead,
    /// because "no buttons" is an observation and the reason is what you act on.
    ///
    /// **It also names its `owner/repo`, and this is the one row where that is not optional.**
    /// Archon answers a git worktree with every run on the machine (`scopeFallback`), so the
    /// gate above may well belong to a different project — and the inbox row already carries the
    /// repo for exactly that reason. Here the stake is higher than opening the wrong pull
    /// request: these buttons approve or reject somebody's work, and "an unfamiliar entry is
    /// self-evidently unfamiliar" is only true if the row says whose it is.
    private func gatedLine(_ run: ArchonRun) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                // Running breathes; a gate holds still and waits. Two shapes as well as two
                // colours, so the states are told apart without relying on hue.
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.attention)
                    .frame(width: 6, height: 6)
                Text(run.workflowName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                runID(run.id)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let repository = ArchonRunLink.parse(workingPath: run.workingPath)?.repository {
                    Text(repository)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.textFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text(Self.detail(of: run))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.textFaint)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 13)
            if run.isAwaitingDecision { verbs(for: run) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
    }

    /// What the gate says, or why it is not yours to answer.
    private static func detail(of run: ArchonRun) -> String {
        guard let gate = run.gate else {
            return "Paused with no gate recorded — Archon cannot resolve this one either."
        }
        if let blocked = gate.blockedReason { return blocked }
        return gate.message.isEmpty ? gate.nodeId : gate.message
    }

    private func verbs(for run: ArchonRun) -> some View {
        let busy = model.busyRuns.contains(run.id)
        return HStack(spacing: 6) {
            verb("APPROVE", tint: .accent) { choose(.approve, on: run) }
            verb("REJECT", tint: .attention) { choose(.reject, on: run) }
            if busy { ProgressView().controlSize(.small) }
            Spacer()
        }
        .padding(.leading, 13)
        .padding(.top, 2)
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
    }

    private func verb(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .overlay(
                    RoundedRectangle(cornerRadius: 3).strokeBorder(tint.opacity(0.5), lineWidth: 1)
                )
                .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.12)))
                .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }

    private func choose(_ decision: ArchonGateDecision, on run: ArchonRun) {
        Task { await model.choose(decision, on: run, in: workspacePath) }
    }

    /// One thin line, and a subline that changes as the run's nodes advance. **The subline is
    /// the stage's name** — `implement`, `validate` — rather than an excerpt of what it wrote:
    /// the stage is the thing that advances, and the writing is read in Archon's own UI.
    ///
    /// Not a button, unlike the finished row below it. A run still in flight has produced
    /// nothing to open, and a row that looks pressable and is not is worse than one that
    /// plainly is not.
    private func runningLine(_ run: ArchonRun) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                RunningDot()
                Text(run.workflowName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                // The short id, in monospace, because it is the handle every Archon surface
                // uses — `archon workflow get <short-id>` resolves a prefix — and a console
                // shows you the thing you would type. Clicking it takes the full one.
                runID(run.id)
            }
            if let stage = model.stages[run.id] {
                Text(stage)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.textFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 13)
                    .id(stage)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Clipped because the subline slides in from below its own frame; without it the
        // outgoing line is drawn over the row beneath during the crossfade.
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: model.stages[run.id])
        .padding(.vertical, 5)
    }

    /// One finished run, and the one row in the rail that **is** a button: clicking it opens
    /// what the run produced. It mirrors `runningLine`'s geometry deliberately — same dot, same
    /// name, same trailing short id, same subline slot — so the live work and the finished work
    /// read as one list rather than two widgets.
    ///
    /// The subline names the run's `owner/repo`. That is not decoration: Archon answers a git
    /// worktree with every run on the machine, so the row above this one may well belong to a
    /// different project, and "an unfamiliar entry is self-evidently unfamiliar" is only true if
    /// the row says whose it is.
    private func finishedLine(_ run: ArchonRun) -> some View {
        let link = ArchonRunLink.parse(workingPath: run.workingPath)
        // **`.top`, because the id and the × belong to the first line.** They used to be
        // centred over a two-line block; the id has moved out of the button (see below) and
        // aligning the trailing pair to the top is what keeps it exactly where it was drawn,
        // level with the run's name, with no offset to hand-tune.
        return HStack(alignment: .top, spacing: 7) {
            Button {
                model.open(run)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Self.colour(of: ArchonRunsResponse.tint(for: run.status)))
                            .frame(width: 6, height: 6)
                        Text(run.workflowName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                    }
                    if let link {
                        Text(link.repository)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.textFaint)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .padding(.leading, 13)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // A run with no worktree has nowhere to send you, so the row stays a row.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(link == nil)
            .help(link.map { "Open the pull request for \($0.branch)" } ?? "")

            // **Outside the button, and it has to be.** A `Button`'s label is not a place
            // controls live — the button consumes the click — so an id nested inside this row
            // could not be copied without also opening a pull request in a browser. It is the
            // one row in the rail that is itself pressable, and the id is the one part of it
            // that now does something else.
            runID(run.id)

            Button {
                model.dismiss(run, in: workspacePath)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.textFaint)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Revealed on hover: the row is read far more often than it is cleared, and a
            // permanent × on every line turns a list into a form. **Hidden here means gone,
            // not faint** — SwiftUI drops a fully transparent view from hit testing, so the
            // reveal below is what makes this button clickable at all. `ArchonRowReveal` has
            // the measurement.
            .opacity(reveal.dismissOpacity(for: run.id))
            .help("Clear from helm — Archon keeps its own record")
        }
        .padding(.vertical, 4)
        // **The row's own hit region, and it must be spelled out here rather than inherited.**
        // Without it the region an `.onHover` on this `HStack` gets is the *union of whatever
        // children happen to be in it* — the leading button and the id — and the gaps are not
        // in it: the 7pt spacings, the 4pt padding bands, and the whole trailing area beside a
        // 14×14 control on a two-line row. Measured for #180 by clicking a grid over the row:
        // **474 of 1242 points, 38%, reached no view at all**. Clicks rather than hovers
        // because synthetic hover events do not reach SwiftUI at all — but `.contentShape`
        // defaults to `ContentShapeKinds.interaction`, which is one region serving both, so a
        // point no click reaches is a point hover reports `false` for. That included the ×'s
        // own rectangle, so approaching the × hid it, and hiding it made it un-hittable — the
        // control could not be reached by aiming at it. With this line nothing is dead.
        //
        // Keep it above `.onHover`, and keep it whatever else this row gains: it is the only
        // thing standing between a fourth control and exactly this defect again.
        .contentShape(Rectangle())
        .onHover { inside in reveal.update(inside: inside, for: run.id) }
    }

    private static func colour(of tint: ArchonStatusTint) -> Color {
        switch tint {
        case .running: .archonRunning
        case .success: .archonTeal
        case .error: .danger
        case .warning: .attention
        case .neutral: .textMuted
        }
    }
}

/// The running indicator: a dot that breathes, in Archon's `--running` electric blue.
///
/// Motion rather than a word, because the line already carries two and the question it answers
/// — *is anything happening* — is the one a glance should settle. A `ProgressView` spinner was
/// the alternative and reads as "helm is loading", which is a different claim.
private struct RunningDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.archonRunning)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
