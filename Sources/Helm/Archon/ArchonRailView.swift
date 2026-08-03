import SwiftUI

struct ArchonRailView: View {
    @ObservedObject var model: ArchonRailModel
    let workspacePath: String?
    let openRun: (ArchonRunRef) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Color.border.frame(height: 1)
            content
        }
        .frame(width: 320)
        .background(ChromeBackground())
        .task { await model.poll() }
    }

    private var header: some View {
        HStack {
            Text("Archon")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await model.prepareLauncher(workspacePath: workspacePath) }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textMuted)
            .help("Start an Archon workflow")
            .popover(isPresented: $model.isLauncherOpen, arrowEdge: .top) {
                launcher
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure {
            state("Archon unavailable", detail: failure, icon: "exclamationmark.triangle")
        } else if model.runs.isEmpty, model.isRefreshing {
            state("Checking active runs", detail: nil, icon: "clock")
        } else if model.runs.isEmpty {
            state(
                "No active runs", detail: "Running and paused workflows appear here.",
                icon: "checkmark.circle")
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.runs, id: \.id) { run in
                        Button {
                            openRun(ArchonRunRef(id: run.id, workflowName: run.workflowName))
                        } label: {
                            runRow(run)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
    }

    private func runRow(_ run: ArchonRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.workflowName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(run.status)
                    .font(.caption)
                    .foregroundStyle(run.status == "paused" ? Color.accent : Color.textMuted)
            }
            if let step = run.currentStepName {
                Text(step)
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
            HStack {
                Text(run.workingPath ?? "No working path")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let startedAt = run.startedAt { Text(startedAt, style: .relative) }
            }
            .font(.caption2)
            .foregroundStyle(Color.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.surfaceRaised))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func state(_ title: String, detail: String?, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.textMuted)
            Text(title).foregroundStyle(Color.textPrimary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var launcher: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start workflow").font(.headline)

            Picker("Workflow", selection: $model.selectedWorkflow) {
                if model.workflows.isEmpty {
                    Text("No workflows available").tag("")
                }
                ForEach(model.workflows) { workflow in
                    Text(workflow.name).tag(workflow.name)
                }
            }

            TextField("What should the workflow do?", text: $model.input, axis: .vertical)
                .lineLimit(3...6)

            Toggle("Run without an isolated worktree", isOn: $model.noWorktree)
            TextField("Branch to create", text: $model.branch)
                .disabled(model.noWorktree)

            if !model.workflowLoadErrors.isEmpty {
                Text("\(model.workflowLoadErrors.count) workflow file(s) could not be loaded.")
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
            }
            if let failure = model.launcherFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(Color.accent)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.isLauncherOpen = false }
                Button(model.isLaunching ? "Starting…" : "Start") {
                    Task { await model.launch(in: workspacePath) }
                }
                .disabled(model.isLaunching)
            }
        }
        .padding(16)
        .frame(width: 380)
        .foregroundStyle(Color.textPrimary)
        .background(Color.surfaceRaised)
    }
}
