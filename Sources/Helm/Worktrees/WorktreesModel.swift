import Combine
import Foundation

/// The Worktrees drawer's state (#382): every git repository on the machine that has a linked
/// worktree or is one of the bench's workspaces, and every worktree in each.
///
/// **Git is the only source, and nothing is stored.** The list is what the last refresh read,
/// held for as long as the drawer's pane lives so reopening it shows the last answer at once
/// while the next one is read. A refresh runs when the drawer is shown and when the operator
/// asks (`r`); it never polls.
///
/// **A refresh never blocks the window.** Discovery reads the filesystem off the main actor, and
/// the repositories are read `concurrentRepositories` at a time, each published the moment it
/// answers. A repository that fails keeps the rows it last had and says why.
///
/// Cleanup is #141's, unchanged: only a merged, existing, ordinary linked worktree can be
/// cleaned, the operator confirms first, and it goes through its owner — `archon complete` for
/// an Archon branch, `git worktree remove` without force for the rest.
@MainActor
final class WorktreesModel: ObservableObject {
    enum Confirmation: Equatable, Identifiable {
        case row(path: String)
        case cleanAll(repo: GitCommonDir, paths: [String])

        var id: String {
            switch self {
            case let .row(path): "row:\(path)"
            case let .cleanAll(repo, paths): "all:\(repo):\(paths.joined(separator: "\u{0}"))"
            }
        }
    }

    @Published private(set) var repos: [WorktreeRepo] = []
    /// The repositories a bench workspace is in, listed even with no linked worktree.
    @Published private(set) var workspaceRepos: Set<GitCommonDir> = []
    @Published private(set) var isRefreshing = false
    /// Why a repository's last read failed, by common directory.
    @Published private(set) var refreshFailures: [GitCommonDir: String] = [:]
    @Published private(set) var confirmation: Confirmation?
    @Published private(set) var actingPaths: Set<String> = []
    @Published private(set) var actionFailures: [String: String] = [:]

    /// Six: enough to hide one slow `git status`, few enough that a refresh does not take the
    /// machine from the agents working on it. Measured over 364 worktrees in 129 repositories:
    /// about three seconds at eight, with the status reads nearly all of it.
    static let concurrentRepositories = 6

    /// A repository with only its main checkout is not listed unless a workspace is in it: every
    /// clone under `~/Projects` would otherwise be a group of one.
    var listed: [WorktreeRepo] {
        repos.filter { workspaceRepos.contains($0.id) || $0.worktrees.count > 1 }
    }

    var unlistedCount: Int { repos.count - listed.count }

    private let worktreeClient: any WorktreeClient
    private let archonClient: any ArchonClient
    private let discover: @Sendable ([String]) -> [WorktreeDiscovery.Found]

    init(
        worktreeClient: any WorktreeClient = WorktreeCLI(),
        archonClient: any ArchonClient = ArchonCLI(),
        discover: @escaping @Sendable ([String]) -> [WorktreeDiscovery.Found] = {
            WorktreeDiscovery().repositories(workspaces: $0)
        }
    ) {
        self.worktreeClient = worktreeClient
        self.archonClient = archonClient
        self.discover = discover
    }

    func repo(containing path: String) -> WorktreeRepo? {
        repos.first { $0.worktrees.contains { $0.id == path } }
    }

    // MARK: Reading

    /// Find the repositories, then read each. A refresh asked for while one runs is dropped,
    /// not queued: the one running already answers the same question.
    func refresh(workspaces: [String]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let discover = self.discover
        let found = await Task.detached { discover(workspaces) }.value
        let order = found.map(\.commonDir)
        workspaceRepos = Set(found.filter(\.isWorkspace).map(\.commonDir))
        let workspaceRepos = self.workspaceRepos
        repos.removeAll { !order.contains($0.id) }
        refreshFailures = refreshFailures.filter { order.contains($0.key) }

        let client = worktreeClient
        await withTaskGroup(of: (GitCommonDir, Outcome?).self) { group in
            var waiting = order.makeIterator()
            func start(_ dir: GitCommonDir) {
                let lone = workspaceRepos.contains(dir)
                group.addTask {
                    (dir, await Self.read(dir, with: client, statusOfALoneCheckout: lone))
                }
            }
            for _ in 0..<Self.concurrentRepositories {
                guard let dir = waiting.next() else { break }
                start(dir)
            }
            for await (dir, outcome) in group {
                // Hidden mid-refresh: stop starting reads nobody will see, so a quick reopen
                // is not dropped behind a refresh that is only draining.
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if let outcome { apply(outcome, to: dir, order: order) }
                if let dir = waiting.next() { start(dir) }
            }
        }
    }

    private enum Outcome: Sendable {
        case listed([Worktree])
        case failed(String)
    }

    /// nil when cancelled: the drawer was hidden, and nothing about the repository changed.
    private nonisolated static func read(
        _ dir: GitCommonDir, with client: any WorktreeClient, statusOfALoneCheckout: Bool
    ) async -> Outcome? {
        do {
            return .listed(
                try await client.worktrees(in: dir, statusOfALoneCheckout: statusOfALoneCheckout))
        } catch is CancellationError {
            return nil
        } catch {
            return Task.isCancelled ? nil : .failed(error.localizedDescription)
        }
    }

    private func apply(_ outcome: Outcome, to dir: GitCommonDir, order: [GitCommonDir]) {
        switch outcome {
        case let .listed(worktrees):
            refreshFailures[dir] = nil
            let repo = WorktreeRepo(commonDir: dir, worktrees: worktrees)
            if let index = repos.firstIndex(where: { $0.id == dir }) {
                repos[index] = repo
            } else {
                repos.append(repo)
                let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
                repos.sort { rank[$0.id, default: .max] < rank[$1.id, default: .max] }
            }
        case let .failed(reason):
            refreshFailures[dir] = reason
        }
    }

    private func reread(_ dir: GitCommonDir) async {
        guard
            let outcome = await Self.read(
                dir, with: worktreeClient, statusOfALoneCheckout: workspaceRepos.contains(dir))
        else { return }
        apply(outcome, to: dir, order: repos.map(\.id))
    }

    // MARK: Cleanup (#141)

    func requestCleanup(of row: Worktree) {
        guard row.cleanupRoute != nil, repo(containing: row.id) != nil else { return }
        confirmation = .row(path: row.id)
    }

    func requestCleanAll(in repoID: GitCommonDir) {
        guard let repo = repos.first(where: { $0.id == repoID }) else { return }
        let paths = repo.worktrees.filter { $0.cleanupRoute != nil }.map(\.id)
        guard !paths.isEmpty else { return }
        confirmation = .cleanAll(repo: repoID, paths: paths)
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    func confirm() async {
        guard let confirmation else { return }
        self.confirmation = nil
        switch confirmation {
        case let .row(path):
            guard let repo = repo(containing: path) else { return }
            _ = await performCleanup(path: path)
            await reread(repo.id)
        case let .cleanAll(repo, paths):
            for path in paths {
                _ = await performCleanup(path: path)
            }
            await reread(repo)
        }
    }

    private func performCleanup(path: String) async -> Bool {
        guard let repo = repo(containing: path),
            let row = repo.worktrees.first(where: { $0.id == path }),
            let route = row.cleanupRoute,
            !actingPaths.contains(path)
        else { return false }
        actingPaths.insert(path)
        actionFailures[path] = nil
        defer { actingPaths.remove(path) }
        do {
            switch route {
            case let .archon(branch):
                // Archon resolves the project from the working directory: the main checkout.
                guard let main = repo.mainPath else {
                    actionFailures[path] = "\(repo.name) has no main checkout to run archon in."
                    return false
                }
                try await archonClient.complete(branch: branch, in: WorkspacePath(main))
            case let .git(path):
                try await worktreeClient.remove(path: path, in: repo.commonDir)
            }
            return true
        } catch {
            actionFailures[path] = error.localizedDescription
            return false
        }
    }
}
