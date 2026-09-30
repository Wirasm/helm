import Foundation
import HelmWire
import XCTest

@testable import Helm

/// Presence against a real benchd reached only over TCP, on a machine whose files this process
/// cannot read (M5c, #459): the agent in a pane lights its workspace from benchd's report alone.
///
/// **Skipped unless a harness sets it up**, because the Swift gate needs no benchd: a benchd with
/// `BENCH_LISTEN` and a HOME of its own, a terminal pane on its bench whose session's foreground
/// process has a Claude registry row with `"status": "idle"` in that HOME, and this test run with
/// an empty `BENCH_DIR`, another HOME, and benchd's folders denied to it (`sandbox-exec`).
/// `HELM_REMOTE_BENCH_URL` names benchd and `HELM_REMOTE_PANE` the pane.
@MainActor
final class PresenceOverTCPTests: XCTestCase {
    func testTheAgentInAPaneOnARemoteBenchMarksItsWorkspace() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HELM_REMOTE_BENCH_URL"], let raw = env["HELM_REMOTE_PANE"],
            let pane = UUID(uuidString: raw)
        else { throw XCTSkip("needs a benchd over TCP (see the header)") }
        let client = BenchClient(
            endpoint: try BenchRoot.endpoint(environment: ["BENCH_URL": url]).get())
        let workspace = WorkspacePath("/remote/workspace")
        let manager = TerminalManager()
        manager.adopt(terminals: [pane], in: workspace, attaching: [:])

        await manager.foregrounds.refresh(using: client)
        let board = BoardModel(manager: manager)
        board.refresh()

        XCTAssertEqual(board.presence[workspace.value], .notWorking)
    }
}
