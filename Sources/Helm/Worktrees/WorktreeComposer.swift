import SwiftUI

/// The one input the Worktrees drawer has (`n`): a branch for a new worktree of one repository.
/// An existing branch is checked out, one only origin has is tracked, and any other name is a
/// new branch from the default branch. Return makes it; Escape closes the input.
struct WorktreeComposer: View {
    let repoName: String
    let isCreating: Bool
    let failure: String?
    let focus: FocusState<Bool>.Binding
    let submit: (String) -> Void
    let cancel: () -> Void

    @State private var branch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("NEW IN \(repoName.uppercased())")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.textFaint)
                TextField("branch — existing, on origin, or new", text: $branch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .focused(focus)
                    .disabled(isCreating)
                    .onSubmit { submit(branch) }
                    .onKeyPress(.escape) {
                        cancel()
                        return .handled
                    }
                if isCreating { ProgressView().controlSize(.mini) }
                Text("⏎ create · esc cancel")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
            }
            if let failure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.surfaceRaised)
    }
}

/// The words of the confirmation #141 requires before anything is removed: what it loses, said
/// plainly, and who removes it.
enum WorktreesConfirmText {
    @MainActor
    static func title(_ target: WorktreesModel.Confirmation, in model: WorktreesModel) -> String {
        switch target {
        case let .delete(path, _):
            let row = model.repo(containing: path)?.worktrees.first { $0.id == path }
            return "Delete \(row?.record.branchName ?? (path as NSString).lastPathComponent)?"
        case let .cleanMerged(_, paths):
            return "Delete \(paths.count) merged \(paths.count == 1 ? "worktree" : "worktrees")?"
        }
    }

    @MainActor
    static func message(
        _ target: WorktreesModel.Confirmation, in model: WorktreesModel
    )
        -> String
    {
        switch target {
        case let .delete(path, loss):
            let row = model.repo(containing: path)?.worktrees.first { $0.id == path }
            let how: String? = row.flatMap { howSentence($0, loss) }
            return ([path, lossSentence(loss)] + (how.map { [$0] } ?? []))
                .joined(separator: "\n\n")
        case .cleanMerged:
            return "Each is clean and its branch is on the default branch, so nothing is lost; "
                + "each branch goes too. Each is checked again just before it goes."
        }
    }

    static func button(_ target: WorktreesModel.Confirmation) -> String {
        if case let .delete(_, loss) = target, !loss.losesNothing { return "Delete and lose it" }
        return "Delete"
    }

    static func lossSentence(_ loss: WorktreeLoss) -> String {
        guard !loss.losesNothing else {
            let branch = loss.branch.map { " The branch \($0) goes too." } ?? ""
            return "Nothing is lost: it is clean and the default branch has every commit."
                + branch
        }
        return "This loses " + loss.clauses.joined(separator: ", and ") + "."
    }

    static func howSentence(_ row: Worktree, _ loss: WorktreeLoss) -> String? {
        switch row.owner {
        case .archon:
            return "Archon removes it with archon complete: the worktree, its branch and the "
                + "remote branch. Archon itself refuses when there is uncommitted, unpushed or "
                + "unique work, an open pull request or a running workflow."
        case .git where (loss.uncommittedFiles ?? 0) > 0:
            return "git worktree remove --force, because of the uncommitted files."
        case .git:
            return nil
        }
    }
}
