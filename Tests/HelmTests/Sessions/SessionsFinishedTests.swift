import BenchKit
import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The Sessions drawer lists running sessions, and the finished ones only once the operator
/// opens them for that workspace, the newest few. benchd's answer stays whole: this is what the
/// drawer shows of it. Driven from a benchd stand-in (`FakeBenchd`) answering `sessions/all`.
@MainActor
final class SessionsFinishedTests: XCTestCase {
    /// A `sessions/all` row: running, or finished at `at`.
    nonisolated private static func row(_ id: String, finishedAt at: Int? = nil) -> [String: Any] {
        [
            "harness": "claude", "id": id, "cwd": "/w",
            "state": at.map { ["kind": "finished", "at_ms": $0] }
                ?? ["kind": "running", "activity": ["kind": "busy"]],
            "open": at == nil
                ? ["kind": "bench_attach", "session": id]
                : ["kind": "resume", "argv": ["claude", "--resume", id], "cwd": "/w"],
            "updated_at_ms": at ?? 0,
        ]
    }

    private var workspace = WorkspacePath("/w/one")

    private func model(_ server: FakeBenchd) -> SessionsModel {
        let endpoint = server.endpoint
        return SessionsModel(
            actions: SessionsActions(
                list: { path in
                    let answer = try BenchClient.request(
                        BenchSessionsRequest.all(id: "t", workspace: path), at: endpoint,
                        answering: BenchSessionList.self)
                    return try XCTUnwrap(answer.data)
                },
                dismiss: { _, _ in }, resume: { _, _, _ in },
                workspace: { [unowned self] in workspace },
                send: { _ in }, hideDrawer: {}, runInNewTerminal: { _ in nil }))
    }

    func testFinishedSessionsWaitBehindTheirWorkspacesDisclosureTheNewestTen() async throws {
        let server = try FakeBenchd(
            document: BenchFixture.document(
                "/w/one", BenchFixture.bench([BenchFixture.terminal()]), seq: 1))
        defer { server.stop() }
        // benchd's order: running first, then the newest finished.
        let finished = (1...12).map { "done-\($0)" }
        server.answer = { request in
            let rows =
                [Self.row("run-a"), Self.row("run-b")]
                + finished.enumerated().map { Self.row($1, finishedAt: 100 - $0) }
            return ["id": request["id"] ?? "", "status": "ok", "data": ["rows": rows]]
        }
        let model = model(server)
        await model.refresh()
        XCTAssertEqual(model.listed.map(\.id), ["run-a", "run-b"], "running only, at first")
        XCTAssertEqual(model.finished.count, 12, "benchd's answer is whole")

        model.toggleFinished()
        XCTAssertEqual(
            model.listed.map(\.id), ["run-a", "run-b"] + finished.prefix(10),
            "opened: the newest ten, in benchd's order")

        // The keyboard is on a finished row; closing them moves it to one still listed.
        model.selected = "done-3"
        model.toggleFinished()
        XCTAssertEqual(model.selected, "run-a")

        // Per workspace: opened in one, still closed in another.
        model.toggleFinished()
        workspace = WorkspacePath("/w/two")
        XCTAssertFalse(model.showsFinished)
        workspace = WorkspacePath("/w/one")
        XCTAssertTrue(model.showsFinished)
    }
}
