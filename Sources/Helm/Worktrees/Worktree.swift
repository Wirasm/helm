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

enum WorktreeKind: String, Codable, Equatable, Sendable {
    case archon
    case git
    case unknown

    static func classify(branch: String?) -> Self {
        guard let branch else { return .unknown }
        let archonPrefixes = [
            "archon/task-", "archon/issue-", "archon/pr-", "archon/review-", "archon/thread-",
        ]
        return archonPrefixes.contains(where: branch.hasPrefix) ? .archon : .git
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

enum WorktreeCleanupRoute: Codable, Equatable, Sendable {
    case archon(branch: String)
    case git(path: String)
}

struct Worktree: Identifiable, Codable, Equatable, Sendable {
    let record: WorktreeRecord
    let kind: WorktreeKind
    let status: WorktreeStatus
    let mergedState: WorktreeMergedState
    let isMain: Bool
    let exists: Bool

    var id: String { record.path }

    var cleanupRoute: WorktreeCleanupRoute? {
        guard mergedState == .merged,
            !isMain,
            exists,
            !record.isBare,
            !record.isDetached,
            !record.isLocked,
            !record.isPrunable,
            let branch = record.branchName
        else { return nil }

        switch kind {
        case .archon: return .archon(branch: branch)
        case .git: return .git(path: record.path)
        case .unknown: return nil
        }
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
