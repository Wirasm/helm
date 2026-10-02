import BenchKit
import Foundation
import HelmWire
import XCTest

@testable import Helm

/// ⌘⇧N against a real benchd reached only over TCP, on "another machine" (M5c, #459): the note
/// lands in benchd's `~/.prp`, keyed there, and the operator types into it through benchd.
///
/// **Skipped unless a harness sets it up**, because the Swift gate needs no benchd: a benchd with
/// `BENCH_LISTEN` and a HOME of its own (`HELM_REMOTE_HOME`), a git repository in it
/// (`HELM_REMOTE_WORKSPACE`), and this test run with a different, empty HOME and `BENCH_DIR`,
/// under `sandbox-exec` denying benchd's HOME so a direct read or write fails rather than working
/// on the shared disk. `HELM_REMOTE_BENCH_URL` names benchd.
///
/// Written against API that `origin/development` has too, so the same file is the red run there.
@MainActor
final class RemoteNoteOverTCPTests: XCTestCase {
    private var client: BenchClient!
    private var remoteHome: String!
    private var workspace: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HELM_REMOTE_BENCH_URL"], let home = env["HELM_REMOTE_HOME"],
            let workspace = env["HELM_REMOTE_WORKSPACE"]
        else { throw XCTSkip("needs a benchd over TCP (see the header)") }
        client = BenchClient(
            endpoint: try BenchRoot.endpoint(environment: ["BENCH_URL": url]).get())
        remoteHome = home
        self.workspace = workspace
    }

    override func tearDown() {
        client?.stop()
    }

    func testANoteLandsInBenchdsStoreAndTakesTypingThroughBenchd() async throws {
        // `$HOME`, not `NSHomeDirectory()`, which answers the account's home whatever HOME says.
        let home = try XCTUnwrap(ProcessInfo.processInfo.environment["HOME"])
        XCTAssertNotEqual(home, remoteHome, "precondition: two homes")
        XCTAssertFalse(
            FileManager.default.isReadableFile(atPath: workspace),
            "precondition: this process cannot read benchd's disk")
        let model = WorkbenchModel(terminals: TerminalManager(), client: client)
        XCTAssertNotNil(client.document(atLeast: 0, within: 5), "benchd's first document")
        model.send(.workspaceOpen(path: workspace), by: .operatorGesture)
        XCTAssertEqual(model.workspacePath?.value, workspace)

        let made = await model.newNote()
        let id = try XCTUnwrap(made, "no note: \(model.noteFailure ?? "and no reason")")
        let pane = try XCTUnwrap(model.bench?.pane(id))
        guard case let .canvas(.file(path)) = pane.content else {
            return XCTFail("a note is a canvas pane on its file")
        }
        XCTAssertTrue(
            path.value.hasPrefix(remoteHome + "/.prp/"),
            "the note is in benchd's ~/.prp, not this machine's: \(path.value)")
        XCTAssertTrue(path.value.contains("/notes/"), path.value)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: home + "/.prp"),
            "nothing was written on this machine")

        let canvas = model.canvas(for: pane)
        XCTAssertNotNil(canvas.draft, "the note opens into the editor")
        canvas.edit("written from the other machine")
        canvas.saveDraft()
        let read = BenchCanvasFiles(client: client).read(path.value, within: nil)
        XCTAssertEqual(read, .bytes(Data("written from the other machine".utf8)))
    }
}
