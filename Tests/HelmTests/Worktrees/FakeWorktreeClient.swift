import Foundation

@testable import Helm

actor FakeWorktreeClient: WorktreeClient {
    private var response: [Worktree]
    private var responsesByRepository: [GitCommonDir: [Worktree]] = [:]
    private var listFailures: [GitCommonDir: WorktreeCLIError] = [:]
    private var removeFailures: [String: WorktreeCLIError] = [:]
    private var delay: Duration?

    private(set) var listCalls = 0
    private(set) var currentListCalls = 0
    private(set) var maximumListCalls = 0
    private(set) var repositories: [GitCommonDir] = []
    /// Whether each read asked for the status of a repository's lone checkout, in order.
    private(set) var loneStatusAsked: [Bool] = []
    private(set) var removeRequests: [(path: String, repository: GitCommonDir)] = []
    private(set) var removeLosses: [WorktreeLoss] = []
    private(set) var archonRequests: [(branch: String, home: String?, main: String)] = []
    private(set) var createRequests: [(branch: String, repository: GitCommonDir, main: String)] = []
    private var losses: [String: WorktreeLoss] = [:]
    private var lossReads = 0
    private var archonAnswer = "Completed"
    private var archonKeeps = false
    private var createFailure: WorktreeCLIError?

    init(response: [Worktree] = []) {
        self.response = response
    }

    func setResponse(_ response: [Worktree]) { self.response = response }
    func setResponse(_ response: [Worktree], for repository: GitCommonDir) {
        responsesByRepository[repository] = response
    }
    func setListFailure(_ failure: WorktreeCLIError?, for repository: GitCommonDir) {
        listFailures[repository] = failure
    }
    func setRemoveFailure(_ failure: WorktreeCLIError?, for path: String) {
        removeFailures[path] = failure
    }
    func setDelay(_ delay: Duration?) { self.delay = delay }
    func setLoss(_ loss: WorktreeLoss, for path: String) { losses[path] = loss }
    /// `archon complete` answers `said` and, when `keeps`, leaves the worktree where it was.
    func setArchon(said: String, keeps: Bool) {
        archonAnswer = said
        archonKeeps = keeps
    }
    func setCreateFailure(_ failure: WorktreeCLIError?) { createFailure = failure }
    func lossReadCount() -> Int { lossReads }

    func metrics() -> (
        listCalls: Int, maximumListCalls: Int, repositories: [GitCommonDir],
        removeRequests: [(path: String, repository: GitCommonDir)]
    ) {
        (listCalls, maximumListCalls, repositories, removeRequests)
    }

    func worktrees(
        in commonDir: GitCommonDir, statusOfALoneCheckout: Bool
    ) async throws
        -> [Worktree]
    {
        loneStatusAsked.append(statusOfALoneCheckout)
        listCalls += 1
        currentListCalls += 1
        maximumListCalls = max(maximumListCalls, currentListCalls)
        repositories.append(commonDir)
        if let delay { try? await Task.sleep(for: delay) }
        currentListCalls -= 1
        if let failure = listFailures[commonDir] { throw failure }
        return responsesByRepository[commonDir] ?? response
    }

    func loss(of worktree: Worktree, in commonDir: GitCommonDir) async -> WorktreeLoss {
        lossReads += 1
        return losses[worktree.id] ?? .none(branch: worktree.record.branchName)
    }

    /// A removal takes the worktree out of the next listing, as git would.
    func remove(
        _ worktree: Worktree, in commonDir: GitCommonDir, knowing loss: WorktreeLoss
    ) async throws {
        removeRequests.append((worktree.id, commonDir))
        removeLosses.append(loss)
        if let failure = removeFailures[worktree.id] { throw failure }
        drop(worktree.id, from: commonDir)
    }

    func archonComplete(branch: String, home: String?, main: String) async throws -> String {
        archonRequests.append((branch, home, main))
        if !archonKeeps {
            for (repo, rows) in responsesByRepository {
                for row in rows where row.record.branchName == branch { drop(row.id, from: repo) }
            }
        }
        return archonAnswer
    }

    func create(
        branch: String, in commonDir: GitCommonDir, main: String
    ) async throws
        -> String
    {
        createRequests.append((branch, commonDir, main))
        if let createFailure { throw createFailure }
        let path = main + "/.worktrees/" + WorktreePlace.folderName(for: branch)
        responsesByRepository[commonDir, default: response].append(
            .fixture(path: path, branch: branch, mergedState: .merged))
        return path
    }

    private func drop(_ path: String, from repository: GitCommonDir) {
        responsesByRepository[repository] = (responsesByRepository[repository] ?? response)
            .filter { $0.id != path }
    }
}

extension Worktree {
    static func fixture(
        path: String = "/tmp/project-linked", branch: String? = "feature/one",
        mergedState: WorktreeMergedState = .merged,
        isMain: Bool = false, exists: Bool = true, detached: Bool = false,
        locked: Bool = false, prunable: Bool = false, bare: Bool = false,
        status: WorktreeStatus = WorktreeStatus(isDirty: false, tracking: nil, lastCommitAt: nil)
    ) -> Worktree {
        let record = WorktreeRecord(
            path: path, head: "abc", branch: branch.map { "refs/heads/\($0)" },
            isDetached: detached, isLocked: locked, isPrunable: prunable, isBare: bare,
            unrecognisedFields: [])
        return Worktree(
            record: record, status: status, mergedState: mergedState, isMain: isMain,
            exists: exists)
    }
}

extension WorktreeLoss {
    static func none(branch: String?) -> WorktreeLoss {
        WorktreeLoss(
            uncommittedFiles: 0, unmergedCommits: 0, branch: branch,
            defaultBranch: "refs/remotes/origin/main")
    }
}
