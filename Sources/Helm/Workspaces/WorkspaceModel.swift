import Combine
import Foundation
import HelmWire

/// The open folders as benchd's document names them, and each one's git branch.
///
/// **A follower, and nothing else.** benchd owns which workspaces are open and which is on
/// screen (#354); every change to that is a `workspace/*` verb through `WorkbenchModel.send`,
/// and this list moves when the document does (`follow`). Nothing here is saved.
@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var selectedWorkspace: Workspace?
    /// Each workspace's current git branch, for its tab label. Never persisted: see
    /// `refreshBranch(for:)`.
    @Published private(set) var branches: [WorkspacePath: String] = [:]

    /// The selected workspace's path, for anything that needs a root without needing the
    /// workspace itself.
    var selectedWorkspaceRoot: WorkspacePath? { selectedWorkspace?.path }

    private let readBranch: @Sendable (WorkspacePath) async throws -> String?

    init(readBranch: @escaping @Sendable (WorkspacePath) async throws -> String?) {
        self.readBranch = readBranch
    }

    /// Branches read on benchd's machine (`currentBranch(in:host:)`).
    convenience init(host: any BenchHost) {
        self.init { try await Self.currentBranch(in: $0, host: host) }
    }

    /// The workspaces and the selection benchd's document names.
    func follow(_ document: BenchDocument) {
        let listed = document.workspaces.map { Workspace(path: $0.path) }
        for gone in workspaces where !listed.contains(gone) { branches[gone.path] = nil }
        if workspaces != listed { workspaces = listed }
        let active = document.active.map(Workspace.init(path:))
        if selectedWorkspace != active { selectedWorkspace = active }
    }

    /// Ask git which branch a workspace is on now, for its tab label.
    ///
    /// Asked every time, never remembered: before #379 the answer was persisted with a
    /// `branchResolved` flag that stopped every later ask, so a tab showed the branch its folder
    /// had the first time it was opened, across relaunches, forever. A nil answer clears the label,
    /// because a folder that stopped being a repository, or a detached HEAD, has no branch to show.
    /// A read that fails — benchd not answering, git timing out — keeps the label it had: that is
    /// not an answer about the branch.
    ///
    /// The answer is dropped when it arrives too late to be true: the tab's task was cancelled
    /// because the selection moved on and a newer ask is running, or the workspace was closed
    /// while git was running and would otherwise get a label back.
    func refreshBranch(for workspace: Workspace) async {
        let branch: String?
        do {
            branch = try await readBranch(workspace.path)
        } catch {
            return
        }
        guard !Task.isCancelled, workspaces.contains(workspace) else { return }
        branches[workspace.path] = branch
    }
}

extension WorkspaceModel {
    /// `git branch --show-current` on benchd's machine (`BenchHost`, M5c), where the workspace
    /// is. Nil when git answers with no branch: it fails (not a repository) or prints nothing (a
    /// detached HEAD). Throws when there is no answer — benchd not reached or refusing, git timing
    /// out, the ask cancelled — so `refreshBranch` keeps the label it had.
    nonisolated static func currentBranch(
        in path: WorkspacePath, host: any BenchHost
    ) async throws -> String? {
        let result = try await host.run(
            .git(args: ["-C", path.value, "branch", "--show-current"]), timeout: .seconds(10))
        guard result.status == 0 else { return nil }
        let value = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
