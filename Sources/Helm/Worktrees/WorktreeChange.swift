import Foundation

/// What removing a worktree would lose, read from git at the moment the operator asks, so the
/// confirmation names it (#141: never delete unmerged or dirty work without saying so).
///
/// A count git could not answer is nil, and nil counts as a loss: an unknown is never
/// presented as "nothing to lose".
struct WorktreeLoss: Equatable, Sendable {
    /// Lines of `git status --porcelain`: changed, staged and untracked files. 0 for a worktree
    /// whose folder is already gone.
    let uncommittedFiles: Int?
    /// Commits on the worktree's branch (or detached HEAD) that the default branch does not
    /// reach. nil when there is no default branch to compare against.
    let unmergedCommits: Int?
    /// The branch's name, or nil for a detached HEAD.
    let branch: String?
    /// The default branch the commits were counted against, as git names it.
    let defaultBranch: String?

    var losesNothing: Bool { uncommittedFiles == 0 && unmergedCommits == 0 }

    /// A branch is deleted with its worktree only when the default branch already has every
    /// commit on it. An unmerged branch is kept, so a worktree's removal alone loses no commit.
    var deletesBranch: Bool { branch != nil && unmergedCommits == 0 }

    /// What is lost, one clause each, for the confirmation. Empty when nothing is.
    var clauses: [String] {
        var clauses: [String] = []
        switch uncommittedFiles {
        case 0?: break
        case let count?: clauses.append("\(count) uncommitted \(count == 1 ? "file" : "files")")
        case nil: clauses.append("uncommitted work git could not read")
        }
        let base = defaultBranch.map(Self.shortRef) ?? "the default branch"
        switch (unmergedCommits, branch) {
        case (0?, _): break
        case let (count?, branch?):
            clauses.append(
                "\(count) \(count == 1 ? "commit" : "commits") on \(branch) not on \(base) "
                    + "(the branch is kept)")
        case let (count?, nil):
            clauses.append(
                "\(count) detached \(count == 1 ? "commit" : "commits") not on \(base), "
                    + "reachable from no branch")
        case (nil, _): clauses.append("commits git could not compare with a default branch")
        }
        return clauses
    }

    static func shortRef(_ ref: String) -> String {
        for prefix in ["refs/remotes/", "refs/heads/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }
}

/// Where a new worktree goes: `.worktrees/<name>` inside the main checkout when the repository
/// already keeps its worktrees there (the folder exists, or git ignores it), else a sibling
/// folder `<repo>-<name>` beside the main checkout, so nothing lands in a tree git would list.
enum WorktreePlace {
    /// A branch name as a folder name: `feat/drawer` → `feat-drawer`.
    static func folderName(for branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    static func path(for branch: String, main: String, keepsWorktreesInside: Bool) -> String {
        let name = folderName(for: branch)
        let main = URL(fileURLWithPath: main)
        return keepsWorktreesInside
            ? main.appendingPathComponent(".worktrees").appendingPathComponent(name).path
            : main.deletingLastPathComponent()
                .appendingPathComponent("\(main.lastPathComponent)-\(name)").path
    }
}

/// A new worktree's branch: one that exists locally, one only the remote has, or a new one
/// from the default branch.
enum WorktreeBranchSource: Equatable, Sendable {
    case local
    case remote(String)
    case new(from: String)
}
