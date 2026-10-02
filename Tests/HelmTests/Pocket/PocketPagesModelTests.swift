import Foundation
import HelmWire
import PocketKit
import XCTest

/// Pocket's pages and start against a benchd stand-in over TCP (`FakeBenchd`): the pages come
/// from `prp/stores` and `prp/artifacts`, a reply is a `file/write` over what was read, with
/// `notify`, and a start is a `spawn` by helm with the first message as text.
@MainActor
final class PocketPagesModelTests: XCTestCase {
    private let page = "/s/plans/a.plan.html"
    private let live = "/s/plans/a.plan.data.json"

    /// A stand-in whose bench holds `page` on a canvas an agent opened, and whose store lists it.
    /// `liveFile` answers `file/read` of the live file; nil is absent.
    private func benchd(liveFile: @escaping @Sendable () -> String?) throws -> FakeBenchd {
        // Spelled as benchd may spell it: the same file, not the same string.
        let canvas = BenchDocument.Pane(
            id: UUID(), surface: .canvas(path: "/s/plans/./a.plan.html"), opener: UUID())
        // The operator's own canvas: nobody to mail a reply to.
        let own = BenchDocument.Pane(id: UUID(), surface: .canvas(path: "/s/plans/b.plan.html"))
        let server = try FakeBenchd(
            document: BenchFixture.document(
                "/w/helm", BenchFixture.bench([BenchFixture.terminal(), canvas, own]), seq: 1),
            tcp: true)
        server.answer = { [page, live] request in
            let id = request["id"] ?? ""
            let args = request["args"] as? [String: Any] ?? [:]
            func ok(_ data: Any) -> [String: Any] { ["id": id, "status": "ok", "data": data] }
            switch request["verb"] as? String {
            case "prp/stores": return ok(["stores": [], "workspace": "helm-1"])
            case "prp/artifacts":
                return ok([
                    "files": [
                        ["path": page, "relative": "plans/a.plan.html", "modified_ms": 2],
                        [
                            "path": "/s/plans/a.plan.md", "relative": "plans/a.plan.md",
                            "modified_ms": 3,
                        ],
                    ]
                ])
            case "file/read" where args["path"] as? String == live:
                guard let text = liveFile() else { return ok(["kind": "absent"]) }
                return ok(["kind": "bytes", "base64": Data(text.utf8).base64EncodedString()])
            case "file/write":
                // The page wrote first: a write over what it replaced loses, with the newer file.
                let expect = (args["expect"] as? [String: Any])?["text"] as? String
                guard expect == #"{"stale": true}"# else { return ok(["kind": "written"]) }
                let newer = Data(#"{"page": 2}"#.utf8).base64EncodedString()
                return ok(["kind": "changed", "base64": newer])
            case "spawn": return ok(["handle": "s9", "pane": UUID().uuidString])
            default: return ["id": id, "status": "refused", "reason": "not here"]
            }
        }
        return server
    }

    private func connected(to server: FakeBenchd) async throws -> PocketModel {
        let model = PocketModel()
        model.connect(server.endpoint.description)
        for _ in 0..<150 where model.workspaces.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.workspaces, ["/w/helm"], "\(model.state)")
        return model
    }

    func testPagesListTheStoresHTMLAndKnowWhichAnAgentOpened() async throws {
        let server = try benchd { nil }
        defer { server.stop() }
        let model = try await connected(to: server)
        let refusal = await model.loadPages()
        XCTAssertNil(refusal)
        XCTAssertEqual(model.pages.map(\.title), ["plans/a.plan"])
        let pages = model.pages
        XCTAssertEqual(pages.map { model.isOpened($0) }, [true], "the canvas an agent opened")
        let stores = try XCTUnwrap(server.requests.first { $0["verb"] as? String == "prp/stores" })
        XCTAssertEqual((stores["args"] as? [String: Any])?["workspace"] as? String, "/w/helm")
    }

    /// The reply is written over exactly what was read, with `notify`, so benchd mails the
    /// opener; a page with no live file yet is written over nothing.
    func testAReplyIsWrittenOverWhatWasReadAndNotifies() async throws {
        let server = try benchd { #"{"answers": {"q1": "yes"}}"# }
        defer { server.stop() }
        let model = try await connected(to: server)
        _ = await model.loadPages()
        let refusal = await model.reply("keep it", to: try XCTUnwrap(model.pages.first))
        XCTAssertNil(refusal)
        let write = try XCTUnwrap(server.requests.last { $0["verb"] as? String == "file/write" })
        let args = try XCTUnwrap(write["args"] as? [String: Any])
        XCTAssertEqual(args["path"] as? String, live)
        XCTAssertEqual(args["notify"] as? Bool, true)
        let expect = try XCTUnwrap(args["expect"] as? [String: Any])
        XCTAssertEqual(expect["kind"] as? String, "unchanged")
        XCTAssertEqual(expect["text"] as? String, #"{"answers": {"q1": "yes"}}"#)
        let text = try XCTUnwrap(args["text"] as? String)
        XCTAssertTrue(
            text.contains(#""q1" : "yes""#) && text.contains(#""text" : "keep it""#), text)
    }

    /// A reply that lost to a newer write is replayed once on what that writer left.
    func testAReplyThatLostToANewerWriteIsReplayedOnIt() async throws {
        let server = try benchd { #"{"stale": true}"# }
        defer { server.stop() }
        let model = try await connected(to: server)
        _ = await model.loadPages()
        let refusal = await model.reply("again", to: try XCTUnwrap(model.pages.first))
        XCTAssertNil(refusal)
        let writes = server.requests.filter { $0["verb"] as? String == "file/write" }
        XCTAssertEqual(writes.count, 2)
        let last = try XCTUnwrap(writes.last?["args"] as? [String: Any])
        XCTAssertEqual((last["expect"] as? [String: Any])?["text"] as? String, #"{"page": 2}"#)
        XCTAssertTrue((last["text"] as? String ?? "").contains(#""page" : 2"#))
    }

    /// Reading a finished turn on the phone is the operator seeing it: `sessions/seen` by the
    /// operator, so it leaves the top of the agents tab as it does when he focuses its pane.
    func testSeeingAFinishedTurnTellsBenchd() async throws {
        let server = try benchd { nil }
        defer { server.stop() }
        let model = try await connected(to: server)
        let refusal = await model.markSeen(harness: "claude", session: "9496c9f4-8105")
        XCTAssertNotNil(refusal, "the stand-in refuses every verb it does not know")
        let seen = try XCTUnwrap(server.requests.last { $0["verb"] as? String == "sessions/seen" })
        XCTAssertEqual((seen["by"] as? [String: Any])?["kind"] as? String, "operator")
        let args = try XCTUnwrap(seen["args"] as? [String: Any])
        XCTAssertEqual(args["harness"] as? String, "claude")
        XCTAssertEqual(args["id"] as? String, "9496c9f4-8105")
    }

    /// Start is a spawn by helm with the first message as text, so benchd records it as the
    /// operator's and moves no focus on the Mac.
    func testStartSpawnsAnOrchestratorAsHelm() async throws {
        let server = try benchd { nil }
        defer { server.stop() }
        let model = try await connected(to: server)
        let refusal = await model.start(
            "codex", in: "/w/helm", model: "gpt-6", effort: "high", prompt: "Orchestrate slice 3.")
        XCTAssertNil(refusal)
        let spawn = try XCTUnwrap(server.requests.last { $0["verb"] as? String == "spawn" })
        XCTAssertEqual((spawn["by"] as? [String: Any])?["kind"] as? String, "helm")
        let args = try XCTUnwrap(spawn["args"] as? [String: Any])
        XCTAssertEqual(args["agent"] as? String, "codex")
        XCTAssertEqual(args["cwd"] as? String, "/w/helm")
        XCTAssertEqual(args["prompt"] as? String, "Orchestrate slice 3.")
        XCTAssertEqual(args["effort"] as? String, "high")
    }
}
