import Foundation

@testable import Helm

actor FakeArchonClient: ArchonClient {
    var runsResponse: ArchonRunsResponse
    var workflowList: ArchonWorkflowListResponse
    var detail: ArchonRun
    /// Per-id detail, for the rail's preview fan-out. Falls back to `detail`.
    var details: [String: ArchonRun] = [:]
    var acknowledgement: ArchonLaunchAcknowledgement
    var failure: ArchonCLIError?
    /// Fails only the per-run detail call, which is how a run keeps its line and loses its
    /// subline.
    var detailFailure: ArchonCLIError?
    var delay: Duration?

    /// The ack every verb answers with unless a test says otherwise.
    var actionAcknowledgement: ArchonActionAcknowledgement = .fixture()
    var resumeAcknowledgement: ArchonLaunchAcknowledgement = .fixture()
    /// Fails only the resume that follows an approve or reject, which is the branch where the
    /// decision is already recorded and cannot be taken back.
    var resumeFailure: ArchonCLIError?

    private(set) var listCalls = 0
    private(set) var currentListCalls = 0
    private(set) var maximumListCalls = 0
    private(set) var statusFilters: [String?] = []
    private(set) var limits: [Int?] = []
    private(set) var detailRequests: [String] = []
    private(set) var workspacePaths: [String] = []
    private(set) var launchRequests: [ArchonLaunchRequest] = []
    private(set) var actions: [(action: ArchonRunAction, runID: String)] = []
    private(set) var resumedRuns: [String] = []

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
    func setDelay(_ delay: Duration?) { self.delay = delay }
    func setRuns(_ response: ArchonRunsResponse) { runsResponse = response }
    func setDetails(_ details: [String: ArchonRun]) { self.details = details }
    func setAcknowledgement(_ acknowledgement: ArchonLaunchAcknowledgement) {
        self.acknowledgement = acknowledgement
    }
    func setActionAcknowledgement(_ acknowledgement: ArchonActionAcknowledgement) {
        actionAcknowledgement = acknowledgement
    }
    func setResumeFailure(_ failure: ArchonCLIError?) { resumeFailure = failure }
    func setResumeAcknowledgement(_ acknowledgement: ArchonLaunchAcknowledgement) {
        resumeAcknowledgement = acknowledgement
    }

    func metrics() -> (
        listCalls: Int, maximumListCalls: Int, launchRequests: Int, detailRequests: [String],
        statusFilters: [String?], workspacePaths: [String], limits: [Int?], resumedRuns: [String]
    ) {
        (
            listCalls, maximumListCalls, launchRequests.count, detailRequests, statusFilters,
            workspacePaths, limits, resumedRuns
        )
    }

    func lastLaunch() -> ArchonLaunchRequest? { launchRequests.last }
    func actionLog() -> [(action: ArchonRunAction, runID: String)] { actions }

    func runs(
        in workspacePath: String, status: String?, limit: Int?
    ) async throws
        -> ArchonRunsResponse
    {
        listCalls += 1
        currentListCalls += 1
        maximumListCalls = max(maximumListCalls, currentListCalls)
        statusFilters.append(status)
        limits.append(limit)
        workspacePaths.append(workspacePath)
        if let delay { try? await Task.sleep(for: delay) }
        currentListCalls -= 1
        if let failure { throw failure }
        guard let status else { return runsResponse }
        // The CLI filters in the database; the fake filters the same way so a test can tell
        // "asked for completed" from "got everything and hoped".
        return ArchonRunsResponse(
            runs: runsResponse.runs.filter { $0.status == status }, total: runsResponse.total,
            counts: runsResponse.counts, scopeFallback: runsResponse.scopeFallback)
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

    func act(
        _ action: ArchonRunAction, on runID: String, in workspacePath: String
    ) async throws
        -> ArchonActionAcknowledgement
    {
        actions.append((action, runID))
        workspacePaths.append(workspacePath)
        if let failure { throw failure }
        return actionAcknowledgement
    }

    func resume(_ run: ArchonRun) async throws -> ArchonLaunchAcknowledgement {
        resumedRuns.append(run.id)
        if let resumeFailure { throw resumeFailure }
        return resumeAcknowledgement
    }
}

extension ArchonRun {
    static func fixture(
        id: String = "run-1", workflowName: String = "implement", status: String = "running",
        workingPath: String? = "/tmp/project", userMessage: String? = "do the thing",
        nodes: [ArchonNode]? = []
    ) -> ArchonRun {
        ArchonRun(
            id: id, workflowName: workflowName, status: status, workingPath: workingPath,
            userMessage: userMessage, startedAt: nil, completedAt: nil,
            metadata: nil, nodes: nodes)
    }
}

extension ArchonActionAcknowledgement {
    static func fixture(
        ok: Bool = true, action: String = "abandon", cancelled: Bool? = nil,
        resumable: Bool? = nil, error: String? = nil
    ) -> ArchonActionAcknowledgement {
        ArchonActionAcknowledgement(
            ok: ok, runId: "run-1", action: action, workflowName: "implement",
            status: ok ? "cancelled" : nil, cancelled: cancelled, maxAttemptsReached: nil,
            resumable: resumable, error: error)
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
