import Foundation

@testable import Helm

actor FakeArchonClient: ArchonClient {
    var runsResponse: ArchonRunsResponse
    var workflowList: ArchonWorkflowListResponse
    /// What `workflow status --verbose` answers: the live runs with their nodes.
    var statusRuns: [ArchonRun] = []
    var cancellation: ArchonActionAcknowledgement = .fixture(action: "cancel", resumable: nil)
    /// Per-id detail, for the rail's stage fan-out. Falls back to `detail`.
    var acknowledgement: ArchonLaunchAcknowledgement
    var failure: ArchonCLIError?
    /// Fails only the per-run detail call, which is how a run keeps its line and loses its
    /// subline.
    var detailFailure: ArchonCLIError?
    var delay: Duration?
    var decision: ArchonActionAcknowledgement = .fixture()
    var decisionFailure: ArchonCLIError?
    var resumeAcknowledgement: ArchonLaunchAcknowledgement = .fixture()
    var resumeFailure: ArchonCLIError?

    private(set) var listCalls = 0
    private(set) var currentListCalls = 0
    private(set) var maximumListCalls = 0
    private(set) var statusCalls = 0
    private(set) var cancelRequests: [String] = []
    private(set) var workspacePaths: [WorkspacePath] = []
    private(set) var launchRequests: [ArchonLaunchRequest] = []
    private(set) var decisions:
        [(
            decision: ArchonGateDecision, text: String?, runID: String,
            workspacePath: WorkspacePath
        )] = []
    private(set) var resumeRequests: [String] = []

    init(
        runsResponse: ArchonRunsResponse = .fixture(),
        workflowList: ArchonWorkflowListResponse = .init(workflows: [], errors: []),
        acknowledgement: ArchonLaunchAcknowledgement = .fixture()
    ) {
        self.runsResponse = runsResponse
        self.workflowList = workflowList
        self.acknowledgement = acknowledgement
    }

    func setFailure(_ failure: ArchonCLIError?) { self.failure = failure }
    func setDetailFailure(_ failure: ArchonCLIError?) { detailFailure = failure }
    func setDelay(_ delay: Duration?) { self.delay = delay }
    func setRuns(_ response: ArchonRunsResponse) { runsResponse = response }
    func setStatusRuns(_ runs: [ArchonRun]) { statusRuns = runs }
    func setCancellation(_ acknowledgement: ArchonActionAcknowledgement) {
        cancellation = acknowledgement
    }
    func cancels() -> [String] { cancelRequests }
    func setAcknowledgement(_ acknowledgement: ArchonLaunchAcknowledgement) {
        self.acknowledgement = acknowledgement
    }

    func metrics() -> (
        listCalls: Int, maximumListCalls: Int, launchRequests: Int, statusCalls: Int,
        workspacePaths: [WorkspacePath]
    ) {
        (listCalls, maximumListCalls, launchRequests.count, statusCalls, workspacePaths)
    }

    func lastLaunch() -> ArchonLaunchRequest? { launchRequests.last }

    func runs(in workspacePath: WorkspacePath) async throws -> ArchonRunsResponse {
        listCalls += 1
        currentListCalls += 1
        maximumListCalls = max(maximumListCalls, currentListCalls)
        workspacePaths.append(workspacePath)
        if let delay { try? await Task.sleep(for: delay) }
        currentListCalls -= 1
        if let failure { throw failure }
        return runsResponse
    }

    func workflows(in workspacePath: WorkspacePath) async throws -> ArchonWorkflowListResponse {
        workspacePaths.append(workspacePath)
        // Throwing, unlike `runs`: a cancelled `archon` call throws `CancellationError`
        // (`Subprocess.run`), and the workflow load is cancelled with the drawer's task.
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return workflowList
    }

    func status(in workspacePath: WorkspacePath) async throws -> ArchonStatusResponse {
        statusCalls += 1
        workspacePaths.append(workspacePath)
        if let detailFailure { throw detailFailure }
        if let failure { throw failure }
        return ArchonStatusResponse(runs: statusRuns)
    }

    func cancel(
        runID: String, in workspacePath: WorkspacePath
    ) async throws
        -> ArchonActionAcknowledgement
    {
        cancelRequests.append(runID)
        if let failure { throw failure }
        return cancellation
    }

    func launch(_ request: ArchonLaunchRequest) async throws -> ArchonLaunchAcknowledgement {
        launchRequests.append(request)
        if let failure { throw failure }
        return acknowledgement
    }

    func decide(
        _ decision: ArchonGateDecision, text: String?, on runID: String,
        in workspacePath: WorkspacePath
    ) async throws -> ArchonActionAcknowledgement {
        decisions.append((decision, text, runID, workspacePath))
        if let decisionFailure { throw decisionFailure }
        return self.decision
    }

    func resume(_ run: ArchonRun) async throws -> ArchonLaunchAcknowledgement {
        resumeRequests.append(run.id)
        if let resumeFailure { throw resumeFailure }
        return resumeAcknowledgement
    }

    func setDecision(_ acknowledgement: ArchonActionAcknowledgement) {
        decision = acknowledgement
    }
    func setDecisionFailure(_ failure: ArchonCLIError?) { decisionFailure = failure }
    func setResume(_ acknowledgement: ArchonLaunchAcknowledgement) {
        resumeAcknowledgement = acknowledgement
    }
    func setResumeFailure(_ failure: ArchonCLIError?) { resumeFailure = failure }
    func gateCalls() -> (
        decisions: [(
            decision: ArchonGateDecision, text: String?, runID: String,
            workspacePath: WorkspacePath
        )], resumes: [String]
    ) {
        (decisions, resumeRequests)
    }
}

extension ArchonRun {
    static func fixture(
        id: String = "run-1", workflowName: String = "implement", status: String = "running",
        workingPath: String? = "/tmp/project", userMessage: String? = "do the thing",
        completedAt: Date? = nil, nodes: [ArchonNode]? = [], gate: ArchonGate? = nil,
        graph: [String]? = nil, active: [String]? = nil
    ) -> ArchonRun {
        let metadata: Metadata? =
            gate == nil && graph == nil
            ? nil
            : Metadata(
                error: nil, approval: gate,
                terminalGraph: graph.map { Metadata.TerminalGraph(nodeIds: $0) })
        return ArchonRun(
            id: id, workflowName: workflowName, status: status, workingPath: workingPath,
            userMessage: userMessage, startedAt: nil, completedAt: completedAt,
            metadata: metadata, nodes: nodes, activeNodes: active)
    }

    /// A run stopped at a gate that is waiting for the operator.
    static func paused(
        id: String = "run-1", workflowName: String = "implement", gate: ArchonGate = .fixture()
    ) -> ArchonRun {
        .fixture(id: id, workflowName: workflowName, status: "paused", gate: gate)
    }
}

extension ArchonGate {
    static func fixture(
        nodeId: String = "review", message: String = "Ship the migration?",
        type: Kind = .approval, childRunId: String? = nil, captureResponse: Bool = false,
        resolved: String? = nil, decisions: [Declared] = []
    ) -> ArchonGate {
        ArchonGate(
            nodeId: nodeId, message: message, type: type, childRunId: childRunId,
            captureResponse: captureResponse, resolved: resolved, decisions: decisions)
    }
}

extension ArchonActionAcknowledgement {
    /// The field set `workflow approve --json` prints, read off its own `writeJsonLine` call in
    /// `packages/cli/src/commands/workflow.ts` — including `resumable: true`, which is the
    /// whole reason `resume` exists.
    static func fixture(
        ok: Bool = true, action: String = "approve", resumable: Bool? = true,
        cancelled: Bool? = nil, error: String? = nil
    ) -> ArchonActionAcknowledgement {
        ArchonActionAcknowledgement(
            ok: ok, runId: "run-1", action: action, workflowName: "implement",
            cancelled: cancelled, maxAttemptsReached: nil, resumable: resumable, error: error)
    }
}

extension ArchonRunsResponse {
    static func fixture(
        runs: [ArchonRun] = [], counts: [String: Int] = [:], scopeFallback: Bool = false
    ) -> ArchonRunsResponse {
        ArchonRunsResponse(
            runs: runs, total: counts["all"] ?? runs.count, counts: counts,
            scopeFallback: scopeFallback)
    }
}

extension ArchonNode {
    static func fixture(
        nodeId: String = "plan", state: State = .running, outputPreview: String? = nil
    ) -> ArchonNode {
        ArchonNode(
            nodeId: nodeId, state: state, startedAt: nil, durationMs: nil,
            outputPreview: outputPreview, error: nil)
    }
}

extension ArchonLaunchAcknowledgement {
    /// The exact field set `archon workflow run --detach --json` prints — read off its own
    /// `writeJsonLine` call in `packages/cli/src/commands/workflow.ts`, not imagined.
    static func fixture(ok: Bool = true, detached: Bool = true) -> ArchonLaunchAcknowledgement {
        ArchonLaunchAcknowledgement(
            ok: ok, action: "run", detached: detached, workflow: "implement",
            branch: "issue-40", conversationId: "cli-1", logPath: "/tmp/run.log")
    }
}

extension ArchonCLIError {
    /// The shape a missing `archon` produces: exit 127 with the shell's complaint on stderr.
    static func notInstalled() -> ArchonCLIError {
        ArchonCLIError(
            command: "archon workflow runs --json",
            reason: .nonzeroExit(status: 127, stderr: "env: archon: No such file or directory"))
    }
}

extension ArchonModel {
    /// A model whose finished rows open nothing: a test that clicks one passes its own opener.
    convenience init(client: any ArchonClient, defaults: UserDefaults) {
        self.init(client: client, defaults: defaults, opener: ArchonRunOpener { _ in })
    }
}
