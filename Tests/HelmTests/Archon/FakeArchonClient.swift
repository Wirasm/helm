import Foundation
import XCTest

@testable import Helm

actor FakeArchonClient: ArchonClient {
    var runsResponse: ArchonRunsResponse
    var workflowList: ArchonWorkflowListResponse
    /// What `workflow status --verbose` answers: the live runs with their nodes.
    var statusRuns: [ArchonRun] = []
    var cancellation: ArchonActionAcknowledgement = .fixture(action: "cancel")
    /// What `workflow attention` answers.
    var queue: [ArchonAttentionItem] = []
    /// Per-id detail, for the rail's stage fan-out. Falls back to `detail`.
    var acknowledgement: ArchonLaunchAcknowledgement
    var failure: ArchonCLIError?
    /// Fails only the per-run detail call, which is how a run keeps its line and loses its
    /// subline.
    var detailFailure: ArchonCLIError?
    var delay: Duration?
    var answerAcknowledgement: ArchonActionAcknowledgement = .fixture()
    var answerFailure: ArchonCLIError?
    var resumeAcknowledgement: ArchonActionAcknowledgement = .fixture(action: "resume")

    private(set) var listCalls = 0
    private(set) var currentListCalls = 0
    private(set) var maximumListCalls = 0
    private(set) var statusCalls = 0
    private(set) var cancelRequests: [String] = []
    private(set) var workspacePaths: [WorkspacePath] = []
    private(set) var launchRequests: [ArchonLaunchRequest] = []
    private(set) var answers: [(answer: ArchonAnswer, text: String?)] = []
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
    func setQueue(_ items: [ArchonAttentionItem]) { queue = items }
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

    func attention(in workspacePath: WorkspacePath) async throws -> ArchonAttentionResponse {
        if let failure { throw failure }
        return ArchonAttentionResponse(ok: true, items: queue, error: nil)
    }

    func answer(
        _ answer: ArchonAnswer, text: String?, in workspacePath: WorkspacePath
    ) async throws -> ArchonActionAcknowledgement {
        answers.append((answer, text))
        if let delay { try? await Task.sleep(for: delay) }
        if let answerFailure { throw answerFailure }
        return answerAcknowledgement
    }

    func resume(
        runID: String, in workspacePath: WorkspacePath
    ) async throws -> ArchonActionAcknowledgement {
        resumeRequests.append(runID)
        return resumeAcknowledgement
    }

    func setAnswer(_ acknowledgement: ArchonActionAcknowledgement) {
        answerAcknowledgement = acknowledgement
    }
    func setAnswerFailure(_ failure: ArchonCLIError?) { answerFailure = failure }
    func answerCalls() -> [(answer: ArchonAnswer, text: String?)] { answers }
    func resumes() -> [String] { resumeRequests }
}

extension ArchonRun {
    static func fixture(
        id: String = "run-1", workflowName: String = "implement", status: String = "running",
        workingPath: String? = "/tmp/project", userMessage: String? = "do the thing",
        completedAt: Date? = nil, nodes: [ArchonNode]? = [], graph: [String]? = nil,
        active: [String]? = nil
    ) -> ArchonRun {
        let metadata: Metadata? =
            graph.map { Metadata(error: nil, terminalGraph: Metadata.TerminalGraph(nodeIds: $0)) }
        return ArchonRun(
            id: id, workflowName: workflowName, status: status, workingPath: workingPath,
            userMessage: userMessage, startedAt: nil, completedAt: completedAt,
            metadata: metadata, nodes: nodes, activeNodes: active)
    }
}

extension ArchonActionAcknowledgement {
    /// The fields `workflow respond --detach --json` prints, captured from Archon 0.12.
    static func fixture(
        ok: Bool = true, action: String = "respond", error: String? = nil
    ) -> ArchonActionAcknowledgement {
        ArchonActionAcknowledgement(
            ok: ok, runId: "run-1", action: action, continues: ok ? true : nil, error: error)
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
    /// The field set `archon workflow run --detach --json` prints, as captured in
    /// `Fixtures/workflow-run-detach.json`.
    static func fixture(ok: Bool = true, detached: Bool = true) -> ArchonLaunchAcknowledgement {
        ArchonLaunchAcknowledgement(
            ok: ok, action: "run", detached: detached, runId: "run-9", workflow: "implement",
            branch: nil, conversationId: nil, logPath: "/tmp/run.log")
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

extension ArchonAttentionItem {
    /// Items from the captured `Fixtures/workflow-attention.json`: a select, a message, an
    /// approval, a multi-select and a legacy gate, in that order.
    static func captured() throws -> [ArchonAttentionItem] {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "workflow-attention", withExtension: "json",
                subdirectory: "Fixtures"))
        return try JSONDecoder.archon().decode(
            ArchonAttentionResponse.self, from: Data(contentsOf: url)
        ).items
    }

    /// The captured select item, re-addressed to `runId` so it can stand for a fixture run.
    static func select(
        runId: String = "run-1", occurrence: String = "occ-1"
    ) throws
        -> ArchonAttentionItem
    {
        let json = """
            {"kind":"attention","runId":"\(runId)","workflow":"archon-review","pausedAt":null,
             "context":{"workingPath":"/tmp/project","branch":null},"node":"attend__ask",
             "occurrence":"\(occurrence)","message":"**archon-review: decide**\\n\\nMore.",
             "form":"select","options":[{"id":"rerun","label":"Review again"},{"id":"finish"}]}
            """
        return try JSONDecoder.archon().decode(ArchonAttentionItem.self, from: Data(json.utf8))
    }
}
