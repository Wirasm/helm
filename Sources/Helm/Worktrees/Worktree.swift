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

struct WorktreeMetadata: Codable, Equatable, Sendable {
    let diskBytes: Int64?
    let directoryModifiedAt: Date?
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
    let metadata: WorktreeMetadata
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
