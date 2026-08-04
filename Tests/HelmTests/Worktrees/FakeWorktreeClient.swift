import Foundation

@testable import Helm

actor FakeWorktreeClient: WorktreeClient {
    private var response: [Worktree]
    private var responsesByWorkspace: [String: [Worktree]] = [:]
    private var listFailure: WorktreeCLIError?
    private var removeFailures: [String: WorktreeCLIError] = [:]
    private var delay: Duration?

    private(set) var listCalls = 0
    private(set) var currentListCalls = 0
    private(set) var maximumListCalls = 0
    private(set) var workspacePaths: [String] = []
    private(set) var removeRequests: [(path: String, workspacePath: String)] = []

    init(response: [Worktree] = []) {
        self.response = response
    }

    func setResponse(_ response: [Worktree]) { self.response = response }
    func setResponse(_ response: [Worktree], for workspacePath: String) {
        responsesByWorkspace[workspacePath] = response
    }
    func setListFailure(_ failure: WorktreeCLIError?) { listFailure = failure }
    func setRemoveFailure(_ failure: WorktreeCLIError?, for path: String) {
        removeFailures[path] = failure
    }
    func setDelay(_ delay: Duration?) { self.delay = delay }

    func metrics() -> (
        listCalls: Int, maximumListCalls: Int, workspacePaths: [String],
        removeRequests: [(path: String, workspacePath: String)]
    ) {
        (listCalls, maximumListCalls, workspacePaths, removeRequests)
    }

    func worktrees(in workspacePath: String) async throws -> [Worktree] {
        listCalls += 1
        currentListCalls += 1
        maximumListCalls = max(maximumListCalls, currentListCalls)
        workspacePaths.append(workspacePath)
        if let delay { try? await Task.sleep(for: delay) }
        currentListCalls -= 1
        if let listFailure { throw listFailure }
        return responsesByWorkspace[workspacePath] ?? response
    }

    func remove(path: String, in workspacePath: String) async throws {
        removeRequests.append((path, workspacePath))
        if let failure = removeFailures[path] { throw failure }
    }
}

extension Worktree {
    static func fixture(
        path: String = "/tmp/project-linked", branch: String? = "feature/one",
        kind: WorktreeKind? = nil, mergedState: WorktreeMergedState = .merged,
        isMain: Bool = false, exists: Bool = true, detached: Bool = false,
        locked: Bool = false, prunable: Bool = false, bare: Bool = false,
        diskBytes: Int64? = 4_096, modifiedAt: Date? = Date(timeIntervalSince1970: 1_000)
    ) -> Worktree {
        let record = WorktreeRecord(
            path: path, head: "abc", branch: branch.map { "refs/heads/\($0)" },
            isDetached: detached, isLocked: locked, isPrunable: prunable, isBare: bare,
            unrecognisedFields: [])
        return Worktree(
            record: record, kind: kind ?? .classify(branch: branch),
            metadata: WorktreeMetadata(diskBytes: diskBytes, directoryModifiedAt: modifiedAt),
            mergedState: mergedState, isMain: isMain, exists: exists)
    }
}
