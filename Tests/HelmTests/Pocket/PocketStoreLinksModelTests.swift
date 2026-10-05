import Foundation
import HelmWire
import PocketKit
import XCTest

/// Store roots, home and each chat's existing files come from its TCP peer.
@MainActor
final class PocketStoreLinksModelTests: XCTestCase {
    private func server() throws -> FakeBenchd {
        let server = try FakeBenchd(
            document: BenchFixture.document(
                "/remote/project", BenchFixture.bench([BenchFixture.terminal()]), seq: 1),
            tcp: true)
        server.answer = { request in
            let id = request["id"] ?? ""
            let args = request["args"] as? [String: Any] ?? [:]
            func ok(_ data: Any) -> [String: Any] { ["id": id, "status": "ok", "data": data] }
            switch request["verb"] as? String {
            case "prp/stores":
                return ok([
                    "stores": [
                        [
                            "key": "project-1", "name": "project",
                            "dir": "/remote/home/.prp/project-1",
                        ],
                        ["key": "other-1", "name": "other", "dir": "/remote/home/.prp/other-1"],
                    ],
                    "workspace": args["workspace"] as? String == "/remote/other"
                        ? "other-1" : "project-1",
                ])
            case "path/resolve": return ok(["path": "/remote/home", "kind": "directory"])
            case "prp/artifacts":
                let key = args["store"] as? String ?? ""
                return ok([
                    "files": [
                        [
                            "path": "/remote/home/.prp/\(key)/reports/plan.md",
                            "relative": "reports/plan.md", "modified_ms": 1,
                        ]
                    ]
                ])
            default: return ["id": id, "status": "refused", "reason": "not here"]
            }
        }
        return server
    }

    func testRemoteAuthorityAndEachChatsStoreAreIndependent() async throws {
        let server = try server()
        defer { server.stop() }
        let model = PocketModel()
        model.connect(server.endpoint.description)
        let first = try await model.loadStoreLinks(workspace: "/remote/project/worktree").get()
        let second = try await model.loadStoreLinks(workspace: "/remote/other").get()
        XCTAssertEqual(
            first.page("reports/plan.md")?.path, "/remote/home/.prp/project-1/reports/plan.md")
        XCTAssertEqual(
            second.page("reports/plan.md")?.path, "/remote/home/.prp/other-1/reports/plan.md")
        XCTAssertEqual(
            first.page("~/.prp/project-1/plan.md")?.path, "/remote/home/.prp/project-1/plan.md")
        XCTAssertNil(first.page("/Users/phone/.prp/project-1/plan.md"))
        XCTAssertNil(first.page("reports/missing.md"))
        let home = try XCTUnwrap(server.requests.first { $0["verb"] as? String == "path/resolve" })
        XCTAssertEqual((home["args"] as? [String: Any])?["path"] as? String, "~")
        let stores = server.requests.filter { $0["verb"] as? String == "prp/stores" }
        XCTAssertEqual(
            stores.compactMap { ($0["args"] as? [String: Any])?["workspace"] as? String },
            ["/remote/project/worktree", "/remote/other"])
        let inventories = server.requests.filter { $0["verb"] as? String == "prp/artifacts" }
        XCTAssertEqual(
            inventories.compactMap { ($0["args"] as? [String: Any])?["store"] as? String },
            ["project-1", "other-1"])
        model.connect("")
        if case .success = await model.loadStoreLinks(workspace: "/remote/other") {
            XCTFail("a disconnected model supplied authority")
        }
    }

    func testAStoreAnswerFromTheConnectionLeftBehindIsDiscarded() async throws {
        let server = try server()
        defer { server.stop() }
        let answer = server.answer
        let received = expectation(description: "old store query received")
        server.answer = { request in
            if request["verb"] as? String == "prp/stores" {
                received.fulfill()
                // Lets the test change connections before the old query answers.
                Thread.sleep(forTimeInterval: 0.2)
            }
            return answer(request)
        }
        let model = PocketModel()
        model.connect(server.endpoint.description)
        let loading = Task { await model.loadStoreLinks(workspace: "/remote/project") }
        await fulfillment(of: [received], timeout: 3)
        model.connect("")
        if case .success = await loading.value { XCTFail("an old connection supplied authority") }
    }
}
