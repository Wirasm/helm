import XCTest

@testable import Helm

final class ArchonRunTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        JSONDecoder.archon()
    }

    func testStatusDecodesSnakeCaseAndRetainsUnknownRunStatus() throws {
        let data = Data(
            #"{"runs":[{"id":"r1","workflow_name":"ship","status":"waiting-on-new-archon","current_step_name":"review","total_steps":4,"started_at":"2026-08-03T10:00:00.123Z"}]}"#
                .utf8)
        let response = try decoder().decode(ArchonStatusResponse.self, from: data)

        XCTAssertEqual(response.runs[0].workflowName, "ship")
        XCTAssertEqual(response.runs[0].status, "waiting-on-new-archon")
        XCTAssertEqual(response.runs[0].currentStepName, "review")
        XCTAssertNil(response.runs[0].workingPath)
    }

    func testVerboseNodesKeepUpstreamOrderOptionalFieldsAndLiteralPreview() throws {
        let data = Data(
            #"{"id":"r1","workflow_name":"ship","status":"running","nodes":[{"nodeId":"zeta","state":"completed","durationMs":3000,"outputPreview":"kept..."},{"nodeId":"alpha","state":"running","startedAt":"2026-08-03T10:00:00Z"},{"nodeId":"middle","state":"skipped"}]}"#
                .utf8)
        let run = try decoder().decode(ArchonRun.self, from: data)

        XCTAssertEqual(run.nodes?.map(\.nodeId), ["zeta", "alpha", "middle"])
        XCTAssertEqual(run.nodes?.first?.outputPreview, "kept...")
        XCTAssertNil(run.nodes?[1].durationMs)
        XCTAssertNil(run.nodes?[2].startedAt)
    }

    func testUnknownNodeStateFailsInsteadOfGuessing() {
        let data = Data(
            #"{"id":"r1","workflow_name":"ship","status":"running","nodes":[{"nodeId":"x","state":"future"}]}"#
                .utf8)
        XCTAssertThrowsError(try decoder().decode(ArchonRun.self, from: data))
    }

    func testRunReferenceRoundTripsAsSmallAddress() throws {
        let reference = ArchonRunRef(id: "r1", workflowName: "ship")
        XCTAssertEqual(
            try decoder().decode(ArchonRunRef.self, from: JSONEncoder().encode(reference)),
            reference)
    }
}
