import Foundation

/// What a key does in the Worktrees drawer (#382), as a value: the view reads a key press, asks
/// this, and carries the answer out, as `ArchonKeys` does for the Archon drawer.
///
/// **A key that does not apply to the selected worktree does nothing.** `d` on the main
/// checkout is not a request to be refused later; the hint line only offers what applies.
enum WorktreesKeyAction: Equatable {
    case none
    case refresh
    /// Open the worktree as a workspace of its own.
    case openWorkspace(Worktree)
    /// A terminal on the bench, in the worktree's folder.
    case openTerminal(Worktree)
    /// Start typing a branch for a new worktree of this repository.
    case create(repo: GitCommonDir)
    /// Ask to remove one worktree; what it loses is read before the operator confirms.
    case delete(Worktree)
    /// Ask to remove every merged, clean worktree of one repository.
    case cleanMerged(repo: GitCommonDir)
}

enum WorktreesKeys {
    static func action(
        for key: Character, on row: Worktree?, in repo: WorktreeRepo?
    ) -> WorktreesKeyAction {
        switch key {
        case "r":
            return .refresh
        case "\r":
            guard let row, row.exists, !row.record.isBare else { return .none }
            return .openWorkspace(row)
        case "t":
            guard let row, row.exists, !row.record.isBare else { return .none }
            return .openTerminal(row)
        case "n":
            guard let repo, repo.mainPath != nil else { return .none }
            return .create(repo: repo.id)
        case "d":
            guard let row, row.isRemovable else { return .none }
            return .delete(row)
        case "D":
            guard let repo, repo.worktrees.contains(where: \.isMergedAndClean) else { return .none }
            return .cleanMerged(repo: repo.id)
        default:
            return .none
        }
    }

    /// The keys that do something for the selected worktree, for the hint line.
    static func hints(on row: Worktree?, in repo: WorktreeRepo?) -> [String] {
        let labelled: [(Character, String)] = [
            ("\r", "⏎ workspace"), ("t", "t terminal"), ("n", "n new"), ("d", "d delete"),
            ("D", "⇧D clean merged"),
        ]
        return ["↑↓ select", "r refresh"]
            + labelled.filter { action(for: $0.0, on: row, in: repo) != .none }.map(\.1)
    }
}
