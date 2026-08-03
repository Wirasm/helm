import SwiftUI

/// The rail, input first.
///
/// **The order on screen is the argument.** Title, then the field you type in, then the gear
/// that says what Enter will do, and only then what is happening — because the thing done
/// most often is starting the same workflow again, and the thing done least is reading a list
/// of runs that finished. The previous shape had those exactly backwards.
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

    private var header: some View {
        HStack(spacing: 6) {
            Text("Archon")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            liveness
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// One dot and one word. The dot is not decoration: "no runs" and "cannot reach Archon"
    /// used to render identically, and the second is the state where nothing in this rail
    /// will work.
    @ViewBuilder
    private var liveness: some View {
        switch model.liveness {
        case .unknown:
            label("waiting", icon: "circle.dotted", tint: Color.textFaint)
        case .live:
            label("live", icon: "circle.fill", tint: Color.accent)
        case .unreachable:
            label("unreachable", icon: "exclamationmark.triangle.fill", tint: Color.accent)
        }
    }

    private func label(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 7)).foregroundStyle(tint)
            Text(text).font(.caption2).foregroundStyle(Color.textMuted)
        }
    }

    // MARK: - Input

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.surfaceRaised))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            composerFocused ? Color.accent.opacity(0.55) : Color.border,
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
                    .foregroundStyle(Color.accent)
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
        .padding(12)
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
                Image(systemName: "gearshape").font(.system(size: 10))
                Text(model.config.workflow.isEmpty ? "Choose a workflow" : model.config.workflow)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.config.worktree.summary)
                    .foregroundStyle(Color.textFaint)
            }
            .font(.caption2)
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.running, id: \.id) { run in
                    runningLine(run)
                }
                if !model.running.isEmpty, !model.statusCounts.isEmpty {
                    Color.border.frame(height: 1).padding(.vertical, 2)
                }
                ForEach(model.statusCounts) { count in
                    countLine(count)
                }
                if model.running.isEmpty, model.statusCounts.isEmpty {
                    Text(emptyNote)
                        .font(.caption2)
                        .foregroundStyle(Color.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                }
                if model.isScopeFallback {
                    // Archon says so in `--json` rather than letting a caller mistake a global
                    // answer for a project one; passing that on is the whole reason it is
                    // decoded. A git worktree hits this every time — which is the normal way
                    // this repo is worked on.
                    Text("This folder is not a registered Archon project — showing every run.")
                        .font(.caption2)
                        .foregroundStyle(Color.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                if !canOpenRuns, !(model.running.isEmpty && model.statusCounts.isEmpty) {
                    Text("Open a workspace to read a run.")
                        .font(.caption2)
                        .foregroundStyle(Color.textFaint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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
    private func runningLine(_ run: ArchonRun) -> some View {
        Button {
            openRun(.run(id: run.id, workflowName: run.workflowName))
        } label: {
            HStack(alignment: .top, spacing: 8) {
                RunningDot()
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.workflowName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let preview = model.previews[run.id] {
                        Text(preview)
                            .font(.caption2)
                            .foregroundStyle(Color.textFaint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .id(preview)
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    /// Every non-running status is one line and a count. Clicking it opens that list as a
    /// bench pane — the rail stays collapsed, and the reading happens where reading happens.
    private func countLine(_ count: ArchonStatusCount) -> some View {
        Button {
            openRun(.runs(status: count.status))
        } label: {
            HStack(spacing: 6) {
                Text("\(count.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.textMuted)
                Text(count.status)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textMuted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpenRuns)
        .opacity(canOpenRuns ? 1 : 0.5)
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
