import Foundation

@testable import Helm

actor FakeArchonClient: ArchonClient {
    var active: [ArchonRun]
    var workflowList: ArchonWorkflowListResponse
    var detail: ArchonRun
    var acknowledgement: ArchonLaunchAcknowledgement
    var failure: ArchonCLIError?
    var delay: Duration?
    private(set) var activeCalls = 0
    private(set) var currentActiveCalls = 0
    private(set) var maximumActiveCalls = 0
    private(set) var launchRequests: [ArchonLaunchRequest] = []

    init(
        active: [ArchonRun] = [],
        workflowList: ArchonWorkflowListResponse = .init(workflows: [], errors: []),
        detail: ArchonRun = .fixture(),
        acknowledgement: ArchonLaunchAcknowledgement = .fixture()
    ) {
        self.active = active
        self.workflowList = workflowList
        self.detail = detail
        self.acknowledgement = acknowledgement
    }

    func setFailure(_ failure: ArchonCLIError?) { self.failure = failure }
    func setDelay(_ delay: Duration?) { self.delay = delay }
    func setActive(_ active: [ArchonRun]) { self.active = active }
    func metrics() -> (activeCalls: Int, maximumActiveCalls: Int, launchRequests: Int) {
        (activeCalls, maximumActiveCalls, launchRequests.count)
    }

    func activeRuns() async throws -> [ArchonRun] {
        activeCalls += 1
        currentActiveCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, currentActiveCalls)
        if let delay { try? await Task.sleep(for: delay) }
        currentActiveCalls -= 1
        if let failure { throw failure }
        return active
    }

    func workflows(in workspacePath: String) async throws -> ArchonWorkflowListResponse {
        if let failure { throw failure }
        return workflowList
    }

    func run(id: String) async throws -> ArchonRun {
        if let failure { throw failure }
        return detail
    }

    func launch(_ request: ArchonLaunchRequest) async throws -> ArchonLaunchAcknowledgement {
        launchRequests.append(request)
        if let failure { throw failure }
        return acknowledgement
    }
}

extension ArchonRun {
    static func fixture(
        id: String = "run-1", workflowName: String = "implement", status: String = "running",
        workingPath: String? = "/tmp/project", nodes: [ArchonNode]? = []
    ) -> ArchonRun {
        ArchonRun(
            id: id, workflowName: workflowName, status: status, workingPath: workingPath,
            currentStepName: nil, totalSteps: nil, startedAt: nil, completedAt: nil,
            metadata: nil, nodes: nodes)
    }
}

extension ArchonLaunchAcknowledgement {
    static func fixture() -> ArchonLaunchAcknowledgement {
        ArchonLaunchAcknowledgement(
            ok: true, action: "run", detached: true, workflow: "implement",
            branch: "issue-40", conversationId: "cli-1", logPath: "/tmp/run.log")
    }
}
