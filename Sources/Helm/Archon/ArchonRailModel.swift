import Combine
import Foundation

@MainActor
final class ArchonRailModel: ObservableObject {
    static let visibilityKey = "archonRailVisible"

    @Published private(set) var isVisible: Bool
    @Published private(set) var runs: [ArchonRun] = []
    @Published private(set) var failure: String?
    @Published private(set) var isRefreshing = false
    @Published var isLauncherOpen = false
    @Published private(set) var workflows: [ArchonWorkflow] = []
    @Published private(set) var workflowLoadErrors: [ArchonWorkflowLoadError] = []
    @Published private(set) var launcherFailure: String?
    @Published private(set) var isLaunching = false
    @Published var selectedWorkflow = ""
    @Published var input = ""
    @Published var branch = ""
    @Published var noWorktree = false

    private let client: any ArchonClient
    private let defaults: UserDefaults
    private var commands: Set<AnyCancellable> = []

    init(client: any ArchonClient = ArchonCLI(), defaults: UserDefaults = DefaultsDomain.store) {
        self.client = client
        self.defaults = defaults
        isVisible = defaults.bool(forKey: Self.visibilityKey)
        NotificationCenter.default.publisher(for: .helmToggleRail)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.toggleVisibility() }
            }
            .store(in: &commands)
    }

    func toggleVisibility() {
        isVisible.toggle()
        defaults.set(isVisible, forKey: Self.visibilityKey)
    }

    func poll(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            runs = try await client.activeRuns()
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
        }
    }

    func prepareLauncher(workspacePath: String?) async {
        isLauncherOpen = true
        launcherFailure = nil
        workflows = []
        workflowLoadErrors = []
        guard let workspacePath else {
            launcherFailure = "Open a workspace before starting an Archon workflow."
            return
        }
        do {
            let response = try await client.workflows(in: workspacePath)
            workflows = response.workflows
            workflowLoadErrors = response.errors
            if selectedWorkflow.isEmpty { selectedWorkflow = workflows.first?.name ?? "" }
        } catch {
            launcherFailure = error.localizedDescription
        }
    }

    func launch(in workspacePath: String?) async {
        guard !isLaunching else { return }
        let workflow = selectedWorkflow.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchName = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspacePath else {
            launcherFailure = "Open a workspace before starting an Archon workflow."
            return
        }
        guard !workflow.isEmpty else {
            launcherFailure = "Choose a workflow."
            return
        }
        guard !message.isEmpty else {
            launcherFailure = "Enter the workflow input."
            return
        }
        guard noWorktree || !branchName.isEmpty else {
            launcherFailure = "Enter the branch to create, or choose no worktree."
            return
        }

        isLaunching = true
        launcherFailure = nil
        defer { isLaunching = false }
        do {
            let acknowledgement = try await client.launch(
                ArchonLaunchRequest(
                    workspacePath: workspacePath, workflow: workflow, input: message,
                    branch: noWorktree ? nil : branchName, noWorktree: noWorktree))
            guard acknowledgement.ok && acknowledgement.detached else {
                launcherFailure = "Archon did not accept the detached launch."
                return
            }
            await refresh()
            isLauncherOpen = false
            input = ""
            branch = ""
            noWorktree = false
        } catch {
            launcherFailure = error.localizedDescription
        }
    }
}
