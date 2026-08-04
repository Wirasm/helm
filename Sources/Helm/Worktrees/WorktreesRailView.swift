import SwiftUI

struct WorktreesRailView: View {
    @ObservedObject var model: WorktreesRailModel
    let workspacePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.isExpanded {
                expandedContent
            }
        }
        .task(id: workspacePath) { await model.workspaceChanged(to: workspacePath) }
        .alert(item: confirmation) { target in
            switch target {
            case let .row(path):
                Alert(
                    title: Text("Clean this worktree?"),
                    message: Text(cleanupMessage(for: path)),
                    primaryButton: .destructive(Text("Clean")) {
                        Task { await model.confirm(in: workspacePath) }
                    },
                    secondaryButton: .cancel { model.cancelConfirmation() })
            case let .cleanAll(paths):
                Alert(
                    title: Text("Clean \(paths.count) merged worktrees?"),
                    message: Text(
                        "Each visible worktree will use its owning command, one at a time. No force flags are used."
                    ),
                    primaryButton: .destructive(Text("Clean All")) {
                        Task { await model.confirm(in: workspacePath) }
                    },
                    secondaryButton: .cancel { model.cancelConfirmation() })
            }
        }
    }

    private var header: some View {
        Button {
            Task { await model.setExpanded(!model.isExpanded, in: workspacePath) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: model.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text("WORKTREES")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else if model.isExpanded {
                    Text("\(model.rows.count)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.textFaint)
                }
            }
            .foregroundStyle(Color.textMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = model.refreshFailure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        worktreeRow(row)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: 280)

            if !model.cleanableRows.isEmpty {
                HStack {
                    Spacer()
                    Button("CLEAN ALL \(model.cleanableRows.count)") {
                        model.requestCleanAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.danger)
                    .disabled(model.isCleaningAll)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
    }

    private func worktreeRow(_ row: Worktree) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(row.record.branchName ?? (row.record.isDetached ? "detached" : "branchless"))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if row.cleanupRoute != nil {
                    Button("CLEAN") { model.requestCleanup(of: row) }
                        .buttonStyle(.plain)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.danger)
                        .disabled(model.actingPaths.contains(row.id))
                }
            }

            HStack(spacing: 5) {
                Text(kindLabel(row))
                Text(sizeLabel(row.metadata.diskBytes))
                Text(activityLabel(row.metadata.directoryModifiedAt))
                Spacer(minLength: 2)
                Text(mergedLabel(row.mergedState))
            }
            .font(.system(size: 8.5, design: .monospaced))
            .foregroundStyle(Color.textFaint)

            if let failure = model.actionFailures[row.id] {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Color.border.frame(height: 1) }
    }

    private var confirmation: Binding<WorktreesRailModel.Confirmation?> {
        Binding(
            get: { model.confirmation },
            set: { if $0 == nil { model.cancelConfirmation() } })
    }

    private func cleanupMessage(for path: String) -> String {
        guard let row = model.rows.first(where: { $0.id == path }),
            let route = row.cleanupRoute
        else { return path }
        switch route {
        case let .archon(branch):
            return "Archon will complete \(branch) and preserve its lifecycle metadata."
        case let .git(path):
            return "Git will remove \(path) using its normal dirty-worktree guardrails."
        }
    }

    private func kindLabel(_ row: Worktree) -> String {
        if row.isMain { return "main" }
        return row.kind.rawValue
    }

    private func sizeLabel(_ bytes: Int64?) -> String {
        guard let bytes else { return "size —" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func activityLabel(_ date: Date?) -> String {
        guard let date else { return "activity —" }
        return date.formatted(.relative(presentation: .named))
    }

    private func mergedLabel(_ state: WorktreeMergedState) -> String {
        switch state {
        case .merged: "merged"
        case .unmerged: "unmerged"
        case .unknown: "merge?"
        }
    }
}
