import SwiftUI

/// The rail, input first — and dressed as Archon's console rather than as another helm panel.
///
/// **The order on screen is the argument.** Wordmark, then the field you type in, then the gear
/// that says what Enter will do, and only then what is happening — because the thing done
/// most often is starting the same workflow again, and the thing done least is reading a list
/// of runs that finished. The previous shape had those exactly backwards.
///
/// **Why it looks different from the rest of helm, on purpose.** The operator asked for a piece
/// of Archon's console embedded here. Almost none of that is colour: it is density, monospace
/// identifiers a run can actually be addressed by, tracked micro-labels, and hairlines instead
/// of gaps. Colour is two governed tokens — `archonBrand` on the wordmark and the field's
/// focus ring, `archonAttention` on a gate that is waiting for a person — and every other
/// surface here is still helm's palette. *Distinctly Archon's* rather than *foreign*: this
/// sits beside the operator's terminals all day, and the difference between those two is small
/// in a screenshot and large after a week.
struct ArchonRailView: View {
    @ObservedObject var model: ArchonRailModel
    let workspacePath: String?
    /// Whether there is a bench for a run pane to land on. False disables the rows *and says
    /// so* — `WorkbenchModel.openRun` returns nil without one, and a row that silently does
    /// nothing when clicked is worse than a row that says it cannot.
    let canOpenRuns: Bool
    let openRun: (ArchonPaneRef) -> Void

    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Color.border.frame(height: 1)
            composer
            Color.border.frame(height: 1)
            content
        }
        .frame(width: 300)
        .background(ChromeBackground())
        // Keyed on the workspace: switching one cancels the poll and starts a poll about the
        // new one. Without the id the loop would keep asking Archon about the folder helm was
        // showing when the rail opened.
        .task(id: workspacePath) { await model.poll(in: workspacePath) }
    }

    // MARK: - Identity

    private var header: some View {
        HStack(spacing: 7) {
            // The mark, and the whole of Archon's logo that survives at 8 points. Governed
            // colour, not a hex: `Palette.archonBrand`.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.archonBrand)
                .frame(width: 7, height: 7)
                .rotationEffect(.degrees(45))
            Text("ARCHON")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(Color.archonBrand)
            Spacer()
            liveness
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// One dot and one word. The dot is not decoration: "no runs" and "cannot reach Archon"
    /// used to render identically, and the second is the state where nothing in this rail
    /// will work.
    ///
    /// Unreachable is the attention colour rather than the accent, which is what it always
    /// should have been — it rendered in the same teal as `live`, so the one state the
    /// indicator exists to distinguish was the one it did not.
    @ViewBuilder
    private var liveness: some View {
        switch model.liveness {
        case .unknown:
            label("waiting", icon: "circle.dotted", tint: Color.textFaint)
        case .live:
            label("live", icon: "circle.fill", tint: Color.accent)
        case .unreachable:
            label("unreachable", icon: "exclamationmark.triangle.fill", tint: Color.archonAttention)
        }
    }

    private func label(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 7)).foregroundStyle(tint)
            Text(text.uppercased())
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Color.textMuted)
        }
    }

    // MARK: - Input

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            // The same field shape as the chat composer, for the same reason: a vertical-axis
            // `TextField` submits on Return and keeps ⌥Return for a newline, so a one-line
            // instruction costs one keystroke and a paragraph is still possible.
            TextField(prompt, text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.textPrimary)
                .focused($composerFocused)
                .disabled(workspacePath == nil)
                .onSubmit { Task { await model.launch(in: workspacePath) } }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.surfaceRaised))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            composerFocused ? Color.archonBrand.opacity(0.6) : Color.border,
                            lineWidth: 1)
                )

            HStack(spacing: 6) {
                gear
                Spacer()
                if model.isLaunching { ProgressView().controlSize(.small) }
            }

            if let failure = model.launchFailure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(Color.archonAttention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case let .unreachable(reason) = model.liveness {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var prompt: String {
        workspacePath == nil ? ArchonRailModel.noWorkspace : "What should Archon do?"
    }

    /// The gear says what Enter will do before it is pressed. Changing workflow is opening
    /// this, never a different entry point — there is only one way in and it is the field.
    private var gear: some View {
        Button {
            Task { await model.loadWorkflows(in: workspacePath) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gearshape").font(.system(size: 9.5))
                Text(model.config.workflow.isEmpty ? "Choose a workflow" : model.config.workflow)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.config.worktree.summary)
                    .foregroundStyle(Color.textFaint)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.textMuted)
        }
        .buttonStyle(.plain)
        .help("Which workflow Enter launches, and how it isolates")
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

    /// The gear's three isolation choices as one `Hashable` value a `Picker` can tag with —
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

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.active, id: \.id) { run in
                    activeLine(run)
                }
                if !model.active.isEmpty, !model.statusCounts.isEmpty {
                    Color.border.frame(height: 1).padding(.vertical, 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(model.statusCounts) { count in
                        countLine(count)
                    }
                }
                if model.active.isEmpty, model.statusCounts.isEmpty {
                    note(emptyNote).padding(.vertical, 4)
                }
                if let failure = model.actionFailure {
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(Color.archonAttention)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                if model.isScopeFallback {
                    // Archon says so in `--json` rather than letting a caller mistake a global
                    // answer for a project one; passing that on is the whole reason it is
                    // decoded. A git worktree hits this every time — which is the normal way
                    // this repo is worked on.
                    note("This folder is not a registered Archon project — showing every run.")
                        .padding(.top, 8)
                }
                if !canOpenRuns, !(model.active.isEmpty && model.statusCounts.isEmpty) {
                    note("Open a workspace to read a run.").padding(.top, 8)
                }
                dismissedFooter
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Color.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// **The rail admits what it is hiding.** Dismissal is helm's own filter and nothing else
    /// — the runs are still in `archon workflow runs` — so a rail that quietly showed fewer
    /// runs than Archon has would be exactly the lie the split between `abandon` and `dismiss`
    /// exists to avoid. One line, and the way back.
    @ViewBuilder
    private var dismissedFooter: some View {
        if model.dismissedCount > 0 {
            HStack(spacing: 6) {
                Text("\(model.dismissedCount) hidden here · still in Archon")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.textFaint)
                Spacer()
                Button("Show") { model.restoreDismissed(in: workspacePath) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.archonBrand)
            }
            .padding(.top, 10)
        }
    }

    private var emptyNote: String {
        switch model.liveness {
        case .unknown: workspacePath == nil ? ArchonRailModel.noWorkspace : "Checking Archon…"
        case .live: "No runs in this project yet."
        case .unreachable: "Archon could not be reached."
        }
    }

    /// One thin line, and a subline that changes as the run's nodes advance. Everything else a
    /// run has to say — its path, its timings, its whole node fold — is a click away in a pane,
    /// which is where reading belongs.
    ///
    /// **A paused run carries its gate.** Approve and Reject are on the row rather than behind
    /// a right-click, because a run stopped waiting for a person is the one thing in this rail
    /// that is blocked on the operator, and an affordance you have to already know about does
    /// not close that gap. Everything rarer — abandon, dismiss — is in the context menu.
    private func activeLine(_ run: ArchonRun) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                openRun(.run(id: run.id, workflowName: run.workflowName))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        mark(for: run)
                        Text(run.workflowName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        // The short id, in monospace, because it is the handle every Archon
                        // surface uses — `archon workflow get <short-id>` resolves a prefix —
                        // and a console shows you the thing you would type.
                        Text(run.shortID)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.textFaint)
                    }
                    if let preview = model.previews[run.id] {
                        Text(preview)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.textFaint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 13)
                            .id(preview)
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canOpenRuns)
            .opacity(canOpenRuns ? 1 : 0.5)
            // Clipped because the subline slides in from below its own frame; without it the
            // outgoing line is drawn over the row beneath during the crossfade.
            .clipped()
            .animation(.easeInOut(duration: 0.25), value: model.previews[run.id])

            if run.isPaused { gate(for: run) }
        }
        .padding(.vertical, 5)
        .contextMenu { menu(for: run) }
    }

    /// Running breathes; paused holds still and waits. Two shapes as well as two colours, so
    /// the states are told apart without relying on hue.
    @ViewBuilder
    private func mark(for run: ArchonRun) -> some View {
        if run.isPaused {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.archonAttention)
                .frame(width: 6, height: 6)
        } else {
            RunningDot()
        }
    }

    private func gate(for run: ArchonRun) -> some View {
        HStack(spacing: 6) {
            verb("APPROVE", tint: Color.accent) {
                Task { await model.act(.approve(comment: nil), on: run, in: workspacePath) }
            }
            verb("REJECT", tint: Color.archonAttention) {
                Task { await model.act(.reject(reason: nil), on: run, in: workspacePath) }
            }
            if model.busyRuns.contains(run.id) { ProgressView().controlSize(.small) }
            Spacer()
        }
        .padding(.leading, 13)
        .disabled(model.busyRuns.contains(run.id))
        .opacity(model.busyRuns.contains(run.id) ? 0.5 : 1)
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

    /// **Every label here says which system it changes.** `abandon` is Archon's own verb and
    /// really ends the run; `dismiss` is helm's and only stops drawing it. A control called
    /// "Clear" that left the row in `archon workflow runs` would be a lie the operator finds a
    /// week later, so neither word is used for the other's job.
    @ViewBuilder
    private func menu(for run: ArchonRun) -> some View {
        if run.isPaused {
            Button("Approve gate and continue the run") {
                Task { await model.act(.approve(comment: nil), on: run, in: workspacePath) }
            }
            Button("Reject gate") {
                Task { await model.act(.reject(reason: nil), on: run, in: workspacePath) }
            }
            Divider()
        }
        Button("Abandon run in Archon") {
            Task { await model.act(.abandon, on: run, in: workspacePath) }
        }
        Divider()
        Button("Hide from this rail (stays in Archon)") {
            model.dismiss(run, in: workspacePath)
        }
        Button("Copy run id") { Pasteboard.copy(run.id) }
    }

    /// Every collapsed status is one line and a count. Clicking it opens that list as a
    /// bench pane — the rail stays collapsed, and the reading happens where reading happens.
    private func countLine(_ count: ArchonStatusCount) -> some View {
        Button {
            openRun(.runs(status: count.status))
        } label: {
            HStack(spacing: 8) {
                Text("\(count.count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(countTint(for: count.status))
                    .frame(minWidth: 26, alignment: .trailing)
                Text(count.status.uppercased())
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(Color.textFaint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5))
                    .foregroundStyle(Color.textFaint)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpenRuns)
        .opacity(canOpenRuns ? 1 : 0.5)
        .contextMenu {
            // Bulk is the real case: nobody dismisses a hundred completed runs one at a time.
            Button("Hide these \(count.count) \(count.status) runs from this rail") {
                Task { await model.dismissAll(status: count.status, in: workspacePath) }
            }
        }
    }

    /// `failed` is the one collapsed status that is a call to look, and rendering it in the
    /// same grey as `completed` throws that away. It spends the attention token the paused mark
    /// already uses rather than earning a third colour — and only the count, so the line still
    /// reads as a row of the same table.
    private func countTint(for status: String) -> Color {
        status == "failed" ? Color.archonAttention : Color.textMuted
    }
}

/// The running indicator: a dot that breathes.
///
/// Motion rather than a word, because the line already carries two words and the question it
/// answers — *is anything happening* — is the one a glance should settle. A `ProgressView`
/// spinner was the alternative and reads as "helm is loading", which is a different claim.
private struct RunningDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.accent)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

extension WorktreeChoice {
    /// The gear's one-word summary, shown beside the workflow name so Enter is never a guess.
    var summary: String {
        switch self {
        case .automatic: "worktree"
        case .none: "in place"
        case let .branch(name): name.isEmpty ? "branch?" : name
        }
    }
}
