import SwiftUI

/// One worktree in the drawer: its branch, then what git says about it — dirty or clean, ahead
/// and behind its upstream, merged into the default branch, how old its last commit is — and
/// which bench panes are working in it.
struct WorktreeRow: View {
    let row: Worktree
    let occupants: [String]
    let isSelected: Bool
    let isActing: Bool
    let failure: String?
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(branch)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(row.exists ? Color.textPrimary : Color.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let kind { mark(kind, Color.textFaint) }
                Spacer(minLength: 8)
                if isActing { ProgressView().controlSize(.mini) }
                if !occupants.isEmpty {
                    mark(occupants.joined(separator: ", "), Color.accent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            HStack(spacing: 10) {
                mark(dirtyText, dirtyTint)
                if let tracking = trackingText { mark(tracking, Color.textMuted) }
                mark(mergedText, row.mergedState == .merged ? Color.archonTeal : Color.textFaint)
                if let age = ageText { mark(age, Color.textFaint) }
            }
            if let failure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.selection : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    private func mark(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(tint)
    }

    private var branch: String {
        if let name = row.record.branchName { return name }
        if row.record.isBare { return "bare" }
        return row.record.isDetached ? "detached" : "branchless"
    }

    /// `main` for the main checkout, `archon` for an Archon branch, and what git flags a
    /// worktree with: missing, locked, prunable.
    private var kind: String? {
        var words: [String] = []
        if row.isMain { words.append("main") }
        if row.kind == .archon { words.append("archon") }
        if !row.exists { words.append("missing") }
        if row.record.isLocked { words.append("locked") }
        if row.record.isPrunable { words.append("prunable") }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    private var dirtyText: String {
        switch row.status.isDirty {
        case true?: "dirty"
        case false?: "clean"
        case nil: "status ?"
        }
    }

    private var dirtyTint: Color {
        row.status.isDirty == true ? .attention : .textFaint
    }

    private var trackingText: String? {
        switch row.status.tracking {
        case nil: nil
        case .gone: "upstream gone"
        case let .counts(ahead, behind) where ahead == 0 && behind == 0: "in step"
        case let .counts(ahead, behind):
            [ahead > 0 ? "↑\(ahead)" : nil, behind > 0 ? "↓\(behind)" : nil]
                .compactMap { $0 }.joined(separator: " ")
        }
    }

    private var mergedText: String {
        switch row.mergedState {
        case .merged: "merged"
        case .unmerged: "unmerged"
        case .unknown: "merge ?"
        }
    }

    private var ageText: String? {
        row.status.lastCommitAt.map { $0.formatted(.relative(presentation: .named)) }
    }
}
