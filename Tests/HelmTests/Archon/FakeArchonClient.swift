import Foundation

@testable import Helm

actor FakeArchonClient: ArchonClient {
    var runsResponse: ArchonRunsResponse
    var workflowList: ArchonWorkflowListResponse
    var detail: ArchonRun
    /// Per-id detail, for the rail's stage fan-out. Falls back to `detail`.
    var details: [String: ArchonRun] = [:]
    var acknowledgement: ArchonLaunchAcknowledgement
    var failure: ArchonCLIError?
    /// Fails only the per-run detail call, which is how a run keeps its line and loses its
    /// subline.
    var detailFailure: ArchonCLIError?
    var completeFailure: ArchonCLIError?
    var delay: Duration?
    var decision: ArchonActionAcknowledgement = .fixture()
    var decisionFailure: ArchonCLIError?
    var resumeAcknowledgement: ArchonLaunchAcknowledgement = .fixture()
    var resumeFailure: ArchonCLIError?

    private(set) var listCalls = 0
    private(set) var currentListCalls = 0
    private(set) var maximumListCalls = 0
    private(set) var detailRequests: [String] = []
    private(set) var workspacePaths: [String] = []
    private(set) var launchRequests: [ArchonLaunchRequest] = []
    private(set) var completeRequests: [(branch: String, workspacePath: String)] = []
    private(set) var decisions:
        [(
            decision: ArchonGateDecision, text: String?, runID: String, workspacePath: String
        )] = []
    private(set) var resumeRequests: [String] = []

    init(
        runsResponse: ArchonRunsResponse = .fixture(),
        workflowList: ArchonWorkflowListResponse = .init(workflows: [], errors: []),
        detail: ArchonRun = .fixture(),
        acknowledgement: ArchonLaunchAcknowledgement = .fixture()
    ) {
        self.runsResponse = runsResponse
        self.workflowList = workflowList
        self.detail = detail
        self.acknowledgement = acknowledgement
    }

    func setFailure(_ failure: ArchonCLIError?) { self.failure = failure }
    func setDetailFailure(_ failure: ArchonCLIError?) { detailFailure = failure }
    func setCompleteFailure(_ failure: ArchonCLIError?) { completeFailure = failure }
    func setDelay(_ delay: Duration?) { self.delay = delay }
    func setRuns(_ response: ArchonRunsResponse) { runsResponse = response }
    func setDetails(_ details: [String: ArchonRun]) { self.details = details }
    func setAcknowledgement(_ acknowledgement: ArchonLaunchAcknowledgement) {
        self.acknowledgement = acknowledgement
    }

    func metrics() -> (
        listCalls: Int, maximumListCalls: Int, launchRequests: Int, detailRequests: [String],
        workspacePaths: [String]
    ) {
        (listCalls, maximumListCalls, launchRequests.count, detailRequests, workspacePaths)
    }

    func lastLaunch() -> ArchonLaunchRequest? { launchRequests.last }
    func completions() -> [(branch: String, workspacePath: String)] { completeRequests }

    func runs(in workspacePath: String) async throws -> ArchonRunsResponse {
        listCalls += 1
        currentListCalls += 1
        maximumListCalls = max(maximumListCalls, currentListCalls)
        workspacePaths.append(workspacePath)
        if let delay { try? await Task.sleep(for: delay) }
        currentListCalls -= 1
        if let failure { throw failure }
        return runsResponse
    }

    func workflows(in workspacePath: String) async throws -> ArchonWorkflowListResponse {
        workspacePaths.append(workspacePath)
        if let failure { throw failure }
        return workflowList
    }

    func run(id: String, in workspacePath: String) async throws -> ArchonRun {
        detailRequests.append(id)
        workspacePaths.append(workspacePath)
        if let detailFailure { throw detailFailure }
        if let failure { throw failure }
        return details[id] ?? detail
    }

    func launch(_ request: ArchonLaunchRequest) async throws -> ArchonLaunchAcknowledgement {
        launchRequests.append(request)
        if let failure { throw failure }
        return acknowledgement
    }

    func complete(branch: String, in workspacePath: String) async throws {
        completeRequests.append((branch, workspacePath))
        if let completeFailure { throw completeFailure }
        if let failure { throw failure }
    }

    func decide(
        _ decision: ArchonGateDecision, text: String?, on runID: String, in workspacePath: String
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
            decision: ArchonGateDecision, text: String?, runID: String, workspacePath: String
        )], resumes: [String]
    ) {
        (decisions, resumeRequests)
    }
}

extension ArchonRun {
    static func fixture(
        id: String = "run-1", workflowName: String = "implement", status: String = "running",
        workingPath: String? = "/tmp/project", userMessage: String? = "do the thing",
        completedAt: Date? = nil, nodes: [ArchonNode]? = [], gate: ArchonGate? = nil
    ) -> ArchonRun {
        ArchonRun(
            id: id, workflowName: workflowName, status: status, workingPath: workingPath,
            userMessage: userMessage, startedAt: nil, completedAt: completedAt,
            metadata: gate.map { Metadata(error: nil, approval: $0) }, nodes: nodes)
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
        resolved: String? = nil
    ) -> ArchonGate {
        ArchonGate(
            nodeId: nodeId, message: message, type: type, childRunId: childRunId,
            captureResponse: captureResponse, resolved: resolved)
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
