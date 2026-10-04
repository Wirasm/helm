import Foundation
import HelmWire
import PocketKit
import XCTest

/// Store roots and home must come from the TCP peer, and a previous connection is no authority.
@MainActor
final class PocketStoreLinksModelTests: XCTestCase {
    private func server() throws -> FakeBenchd {
        let server = try FakeBenchd(
            document: BenchFixture.document(
                "/remote/project", BenchFixture.bench([BenchFixture.terminal()]), seq: 1),
            tcp: true)
        server.answer = { request in
            let id = request["id"] ?? ""
            switch request["verb"] as? String {
            case "prp/stores":
                return [
                    "id": id, "status": "ok",
                    "data": [
                        "stores": [
                            [
                                "key": "project-1", "name": "project",
                                "dir": "/remote/home/.prp/project-1",
                            ]
                        ]
                    ],
                ]
            case "path/resolve":
                return [
                    "id": id, "status": "ok",
                    "data": ["path": "/remote/home", "kind": "directory"],
                ]
            default: return ["id": id, "status": "refused", "reason": "not here"]
            }
        }
        return server
    }

    func testItUsesRemoteRootsAndHomeAndClearsThemWhenConnectingElsewhere() async throws {
        let server = try server()
        defer { server.stop() }
        let model = PocketModel()
        model.connect(server.endpoint.description)
        let refusal = await model.loadStoreLinks()
        XCTAssertNil(refusal)
        XCTAssertEqual(
            model.storeLinks.page("~/.prp/project-1/plan.md")?.path,
            "/remote/home/.prp/project-1/plan.md")
        XCTAssertNil(model.storeLinks.page("/Users/phone/.prp/project-1/plan.md"))
        let home = try XCTUnwrap(server.requests.first { $0["verb"] as? String == "path/resolve" })
        XCTAssertEqual((home["args"] as? [String: Any])?["path"] as? String, "~")
        model.connect("")
        XCTAssertNil(model.storeLinks.page("~/.prp/project-1/plan.md"))
        XCTAssertNil(model.storeLinks.page("/remote/home/.prp/project-1/plan.md"))
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
        let loading = Task { await model.loadStoreLinks() }
        await fulfillment(of: [received], timeout: 3)
        model.connect("")
        _ = await loading.value
        XCTAssertNil(model.storeLinks.page("/remote/home/.prp/project-1/plan.md"))
    }
}
