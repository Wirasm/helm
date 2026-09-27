import Foundation

/// What a key does in the Worktrees drawer (#382), as a value: the view reads a key press, asks
/// this, and carries the answer out, as `ArchonKeys` does for the Archon drawer.
///
/// **A key that does not apply to the selected worktree does nothing.** `d` on an unmerged
/// worktree is not a request to be refused later; the hint line only offers what applies.
enum WorktreesKeyAction: Equatable {
    case none
    case refresh
    /// Ask to clean one worktree; the model's confirmation follows.
    case clean(Worktree)
    /// Ask to clean every cleanable worktree of one repository.
    case cleanAll(repo: GitCommonDir)
}

enum WorktreesKeys {
    static func action(
        for key: Character, on row: Worktree?, in repo: WorktreeRepo?
    ) -> WorktreesKeyAction {
        switch key {
        case "r":
            return .refresh
        case "d":
            guard let row, row.cleanupRoute != nil else { return .none }
            return .clean(row)
        case "D":
            guard let repo, repo.worktrees.contains(where: { $0.cleanupRoute != nil })
            else { return .none }
            return .cleanAll(repo: repo.id)
        default:
            return .none
        }
    }

    /// The keys that do something for the selected worktree, for the hint line.
    static func hints(on row: Worktree?, in repo: WorktreeRepo?) -> [String] {
        var hints = ["↑↓ select", "r refresh"]
        if action(for: "d", on: row, in: repo) != .none { hints.append("d clean") }
        if action(for: "D", on: row, in: repo) != .none { hints.append("⇧D clean merged") }
        return hints
    }
}
