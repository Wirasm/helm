import Combine
import Foundation

@MainActor
final class WorktreesRailModel: ObservableObject {
    enum Confirmation: Equatable, Identifiable {
        case row(path: String)
        case cleanAll(paths: [String])

        var id: String {
            switch self {
            case let .row(path): "row:\(path)"
            case let .cleanAll(paths): "all:\(paths.joined(separator: "\u{0}"))"
            }
        }
    }

    @Published private(set) var isExpanded = false
    @Published private(set) var rows: [Worktree] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshingWorkspace: String?
    @Published private(set) var confirmation: Confirmation?
    @Published private(set) var actingPaths: Set<String> = []
    @Published private(set) var isCleaningAll = false
    @Published private(set) var refreshFailure: String?
    @Published private(set) var actionFailures: [String: String] = [:]

    var cleanableRows: [Worktree] { rows.filter { $0.cleanupRoute != nil } }

    private let worktreeClient: any WorktreeClient
    private let archonClient: any ArchonClient
    private var currentWorkspace: String?
    private var workspaceGeneration = 0
    private var refreshesInFlight: Set<String> = []

    init(worktreeClient: any WorktreeClient, archonClient: any ArchonClient) {
        self.worktreeClient = worktreeClient
        self.archonClient = archonClient
    }

    func setExpanded(_ expanded: Bool, in workspacePath: String?) async {
        let changed = expanded != isExpanded
        isExpanded = expanded
        if expanded {
            if workspacePath != currentWorkspace {
                await workspaceChanged(to: workspacePath)
            } else if changed {
                await refresh(in: workspacePath)
            }
        } else {
            workspaceGeneration += 1
            refreshFailure = nil
            confirmation = nil
        }
    }

    func workspaceChanged(to workspacePath: String?) async {
        guard workspacePath != currentWorkspace else {
            if isExpanded, rows.isEmpty { await refresh(in: workspacePath) }
            return
        }
        currentWorkspace = workspacePath
        workspaceGeneration += 1
        confirmation = nil
        actionFailures = [:]
        rows = []
        guard let workspacePath else {
            rows = []
            refreshFailure = nil
            return
        }
        guard isExpanded else { return }
        await refresh(in: workspacePath)
    }

    func refresh(in workspacePath: String?) async {
        guard isExpanded, let workspacePath else {
            if workspacePath == nil {
                currentWorkspace = nil
                rows = []
                refreshFailure = nil
            }
            return
        }
        if currentWorkspace != workspacePath {
            currentWorkspace = workspacePath
            workspaceGeneration += 1
        }
        guard !refreshesInFlight.contains(workspacePath) else { return }
        let generation = workspaceGeneration
        refreshesInFlight.insert(workspacePath)
        updateRefreshingState()
        defer {
            refreshesInFlight.remove(workspacePath)
            updateRefreshingState()
        }
        do {
            let response = try await worktreeClient.worktrees(in: workspacePath)
            guard isExpanded, currentWorkspace == workspacePath, generation == workspaceGeneration
            else { return }
            rows = response
            refreshFailure = nil
        } catch is CancellationError {
            return
        } catch {
            guard isExpanded, currentWorkspace == workspacePath, generation == workspaceGeneration
            else { return }
            refreshFailure = error.localizedDescription
        }
    }

    func requestCleanup(of row: Worktree) {
        guard row.cleanupRoute != nil, rows.contains(where: { $0.id == row.id }) else { return }
        confirmation = .row(path: row.id)
    }

    func requestCleanAll() {
        let paths = cleanableRows.map(\.id)
        guard !paths.isEmpty else { return }
        confirmation = .cleanAll(paths: paths)
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    func confirm(in workspacePath: String?) async {
        guard let workspacePath, workspacePath == currentWorkspace, let confirmation else {
            self.confirmation = nil
            return
        }
        self.confirmation = nil
        switch confirmation {
        case let .row(path):
            _ = await performCleanup(path: path, in: workspacePath)
            await refresh(in: workspacePath)
        case let .cleanAll(paths):
            isCleaningAll = true
            for path in paths {
                _ = await performCleanup(path: path, in: workspacePath)
            }
            isCleaningAll = false
            await refresh(in: workspacePath)
        }
    }

    private func performCleanup(path: String, in workspacePath: String) async -> Bool {
        guard workspacePath == currentWorkspace,
            let row = rows.first(where: { $0.id == path }),
            let route = row.cleanupRoute,
            !actingPaths.contains(path)
        else { return false }
        actingPaths.insert(path)
        actionFailures[path] = nil
        defer { actingPaths.remove(path) }
        do {
            switch route {
            case let .archon(branch):
                try await archonClient.complete(branch: branch, in: workspacePath)
            case let .git(path):
                try await worktreeClient.remove(path: path, in: workspacePath)
            }
            return true
        } catch {
            actionFailures[path] = error.localizedDescription
            return false
        }
    }

    private func updateRefreshingState() {
        isRefreshing = !refreshesInFlight.isEmpty
        refreshingWorkspace = refreshesInFlight.first
    }
}
