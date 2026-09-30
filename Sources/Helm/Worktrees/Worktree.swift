import Foundation

struct WorktreeRecord: Codable, Equatable, Sendable {
    let path: String
    let head: String?
    let branch: String?
    let isDetached: Bool
    let isLocked: Bool
    let isPrunable: Bool
    let isBare: Bool
    let unrecognisedFields: [String]

    var branchName: String? {
        guard let branch else { return nil }
        return branch.hasPrefix("refs/heads/")
            ? String(branch.dropFirst("refs/heads/".count)) : branch
    }
}

/// Who removes a worktree. Archon keeps a record of the worktrees it makes, so one of its own
/// goes through `archon complete`, which updates that record; everything else is git's.
enum WorktreeOwner: Codable, Equatable, Sendable {
    case git
    /// `home` is the Archon home the worktree lives under (`~/.archon`, `~/.archon-<name>`),
    /// which is the database `archon complete` has to read. nil for a worktree recognised only
    /// by its branch name, which the default home is asked about.
    case archon(home: String?)

    static let archonBranchPrefixes = [
        "archon/task-", "archon/issue-", "archon/pr-", "archon/review-", "archon/thread-",
    ]

    /// Archon's by where it lives — `<home>/.archon*/workspaces/<owner>/<repo>/worktrees/…`,
    /// the layout Archon makes and benchd's `git/repositories` reads — or by a branch name only Archon
    /// gives out. Anything else under an Archon home, such as a worktree made beside Archon's
    /// own clone in `…/<repo>/source`, is git's: Archon has no record of it.
    static func of(path: String, branch: String?) -> WorktreeOwner {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for index in parts.indices
        where index + 5 < parts.count && parts[index].hasPrefix(".archon")
            && parts[index + 1] == "workspaces" && parts[index + 4] == "worktrees"
        {
            return .archon(home: parts[...index].joined(separator: "/"))
        }
        if let branch, archonBranchPrefixes.contains(where: branch.hasPrefix) {
            return .archon(home: nil)
        }
        return .git
    }
}

/// What git says about one worktree's state, each part read once per repository refresh.
/// A part git could not answer is nil and the row says so, rather than guessing "clean".
struct WorktreeStatus: Codable, Equatable, Sendable {
    /// `git status --porcelain` printed anything: a change, staged or not, or an untracked file.
    let isDirty: Bool?
    /// Against the branch's upstream; nil when it has none, or git wrote words this build
    /// does not read.
    let tracking: WorktreeTracking?
    /// The branch tip's committer date; nil for a detached HEAD.
    let lastCommitAt: Date?

    static let unknown = WorktreeStatus(isDirty: nil, tracking: nil, lastCommitAt: nil)
}

/// A branch against its upstream, as `%(upstream:track,nobracket)` reports it.
enum WorktreeTracking: Codable, Equatable, Sendable {
    case counts(ahead: Int, behind: Int)
    /// The upstream is configured but its ref is gone — usually a merged and deleted PR branch.
    case gone

    /// `ahead 1, behind 2`, `ahead 1`, `behind 2`, `gone`, or empty (in step). nil only for text
    /// git does not write, so a new spelling shows as unknown instead of as "in step".
    static func parse(_ text: String) -> WorktreeTracking? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text == "gone" { return .gone }
        var ahead = 0
        var behind = 0
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { return nil }
            switch words[0] {
            case "ahead": ahead = count
            case "behind": behind = count
            default: return nil
            }
        }
        return .counts(ahead: ahead, behind: behind)
    }
}

enum WorktreeMergedState: String, Codable, Equatable, Sendable {
    case merged
    case unmerged
    case unknown
}

struct Worktree: Identifiable, Codable, Equatable, Sendable {
    let record: WorktreeRecord
    let status: WorktreeStatus
    let mergedState: WorktreeMergedState
    let isMain: Bool
    let exists: Bool

    var id: String { record.path }

    var owner: WorktreeOwner { .of(path: record.path, branch: record.branchName) }

    /// Whether this worktree can be removed at all: never the main checkout or a bare
    /// repository, never a worktree git has locked, and never an Archon one without the branch
    /// `archon complete` is asked about. What removing it would lose is a separate question,
    /// `WorktreeLoss`, asked when the operator asks to delete it.
    var isRemovable: Bool {
        guard !isMain, !record.isBare, !record.isLocked else { return false }
        if case .archon = owner { return record.branchName != nil }
        return true
    }

    /// Removable with nothing to lose, going by the last refresh: clean, and its branch merged
    /// into the default branch. What `⇧D` removes without naming a loss.
    var isMergedAndClean: Bool {
        isRemovable && exists && mergedState == .merged && status.isDirty == false
            && record.branchName != nil
    }
}

/// A repository's identity: its common git directory, the one thing every worktree of it
/// shares. A type rather than a `String` so it cannot be passed where a worktree's own path
/// belongs — the two sit side by side in every call that removes one.
struct GitCommonDir: Hashable, Comparable, Sendable, CustomStringConvertible {
    let path: String

    init(_ path: String) {
        self.path = path
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.path < rhs.path }
    var description: String { path }
}

/// One repository and every worktree `git worktree list` knows for it, the main one first.
///
/// **Identified by its common git directory**, the one thing every worktree of a repository
/// shares: two checkouts of one repository are one entry, and a worktree Archon made under
/// `~/.archon` lands with the repository it was made from.
struct WorktreeRepo: Identifiable, Equatable, Sendable {
    let commonDir: GitCommonDir
    let worktrees: [Worktree]

    var id: GitCommonDir { commonDir }

    /// The main checkout, where a repository-wide command runs. nil for a bare repository.
    var mainPath: String? {
        worktrees.first.flatMap { $0.isMain && !$0.record.isBare ? $0.record.path : nil }
    }

    /// The main checkout's folder name, or the common directory's for a bare repository.
    var name: String {
        let url = URL(fileURLWithPath: mainPath ?? commonDir.path)
        let last = url.lastPathComponent
        return last == ".git" ? url.deletingLastPathComponent().lastPathComponent : last
    }
}
