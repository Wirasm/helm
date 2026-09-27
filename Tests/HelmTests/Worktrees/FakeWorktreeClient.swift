import Foundation

@testable import Helm

actor FakeWorktreeClient: WorktreeClient {
    private var response: [Worktree]
    private var responsesByRepository: [String: [Worktree]] = [:]
    private var listFailures: [String: WorktreeCLIError] = [:]
    private var removeFailures: [String: WorktreeCLIError] = [:]
    private var delay: Duration?

    private(set) var listCalls = 0
    private(set) var currentListCalls = 0
    private(set) var maximumListCalls = 0
    private(set) var repositories: [String] = []
    private(set) var removeRequests: [(path: String, repository: String)] = []

    init(response: [Worktree] = []) {
        self.response = response
    }

    func setResponse(_ response: [Worktree]) { self.response = response }
    func setResponse(_ response: [Worktree], for repository: String) {
        responsesByRepository[repository] = response
    }
    func setListFailure(_ failure: WorktreeCLIError?, for repository: String) {
        listFailures[repository] = failure
    }
    func setRemoveFailure(_ failure: WorktreeCLIError?, for path: String) {
        removeFailures[path] = failure
    }
    func setDelay(_ delay: Duration?) { self.delay = delay }

    func metrics() -> (
        listCalls: Int, maximumListCalls: Int, repositories: [String],
        removeRequests: [(path: String, repository: String)]
    ) {
        (listCalls, maximumListCalls, repositories, removeRequests)
    }

    func worktrees(inRepository commonDir: String) async throws -> [Worktree] {
        listCalls += 1
        currentListCalls += 1
        maximumListCalls = max(maximumListCalls, currentListCalls)
        repositories.append(commonDir)
        if let delay { try? await Task.sleep(for: delay) }
        currentListCalls -= 1
        if let failure = listFailures[commonDir] { throw failure }
        return responsesByRepository[commonDir] ?? response
    }

    func remove(path: String, inRepository commonDir: String) async throws {
        removeRequests.append((path, commonDir))
        if let failure = removeFailures[path] { throw failure }
    }
}

extension Worktree {
    static func fixture(
        path: String = "/tmp/project-linked", branch: String? = "feature/one",
        kind: WorktreeKind? = nil, mergedState: WorktreeMergedState = .merged,
        isMain: Bool = false, exists: Bool = true, detached: Bool = false,
        locked: Bool = false, prunable: Bool = false, bare: Bool = false,
        status: WorktreeStatus = .unknown
    ) -> Worktree {
        let record = WorktreeRecord(
            path: path, head: "abc", branch: branch.map { "refs/heads/\($0)" },
            isDetached: detached, isLocked: locked, isPrunable: prunable, isBare: bare,
            unrecognisedFields: [])
        return Worktree(
            record: record, kind: kind ?? .classify(branch: branch), status: status,
            mergedState: mergedState, isMain: isMain, exists: exists)
    }
}
