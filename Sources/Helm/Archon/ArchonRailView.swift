import SwiftUI

/// The rail, reduced to what the operator kept.
///
/// **Five things render, top to bottom, and nothing else**: the Archon title, the field you
/// type in, the button that sends it, one line per running run with a subline naming the stage
/// it is on, and one collapsed count per other status. No headers, no hints, no empty-state
/// prose, no footers, no liveness word. The version this replaces had all of them and the
/// verdict was *"too much bloat"*.
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
    let workspacePath: String?

    @FocusState private var composerFocused: Bool

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
                .onSubmit { launch() }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.surfaceRaised))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            composerFocused ? Color.archonMagenta.opacity(0.6) : Color.border,
                            lineWidth: 1)
                )

            HStack(spacing: 6) {
                settings
                Spacer()
                send
            }

            if let failure = model.launchFailure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(Color.archonError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var prompt: String {
        workspacePath == nil ? ArchonRailModel.noWorkspace : "What should Archon do?"
    }

    /// **Thin, and the second element carrying the gradient.** `.brand-bar` in the console is a
    /// solid gradient fill on a CTA; this is that at helm's scale. The label is `Color.surface`
    /// rather than white or black, because the stops are dark in the light appearance and
    /// bright in the dark one — the surface colour is the knockout that is right in both, and
    /// `PaletteTests` holds every stop to the contrast floor that makes it so.
    private var send: some View {
        Button(action: launch) {
            Text("SEND")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Color.surface)
                .padding(.horizontal, 11)
                .padding(.vertical, 3.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(.archonBrand))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(model.isLaunching || workspacePath == nil)
        .opacity(model.isLaunching || workspacePath == nil ? 0.4 : 1)
    }

    private func launch() {
        Task { await model.launch(in: workspacePath) }
    }

    /// An icon, not a sentence — the rail renders five things, and "which workflow Enter
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

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.running, id: \.id) { run in
                    runningLine(run)
                }
                if !model.running.isEmpty, !model.statusCounts.isEmpty {
                    Color.border.frame(height: 1).padding(.vertical, 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(model.statusCounts) { count in
                        countLine(count)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    /// One thin line, and a subline that changes as the run's nodes advance. **The subline is
    /// the stage's name** — `implement`, `validate` — rather than an excerpt of what it wrote:
    /// the stage is the thing that advances, and the writing is read in Archon's own UI.
    ///
    /// Not a button. There is nowhere for a click to go now that a run does not open as a
    /// pane, and a row that looks pressable and is not is worse than one that plainly is not.
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
                // shows you the thing you would type.
                Text(run.shortID)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.textFaint)
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

    /// A label and a count. **Clicking it does nothing** — there is no pane to open and no
    /// expansion to show, so there is no chevron either. It is a number.
    private func countLine(_ count: ArchonStatusCount) -> some View {
        HStack(spacing: 8) {
            Text("\(count.count)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Self.colour(of: ArchonRunsResponse.tint(for: count.status)))
                .frame(minWidth: 26, alignment: .trailing)
            Text(count.status.uppercased())
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Color.textFaint)
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private static func colour(of tint: ArchonStatusTint) -> Color {
        switch tint {
        case .running: .archonRunning
        case .success: .archonTeal
        case .error: .archonError
        case .warning: .archonAttention
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
