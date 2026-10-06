import AppKit
import HelmWire
import XCTest

@testable import Helm

/// A ⌘-clicked store path, from ghostty's `open_url` to the `pane/open` helm sends.
///
/// A real `TerminalSession` and `WorkbenchModel` against a toy benchd (`ToyBench`) that answers
/// `prp/stores` and `path/resolve` over a temporary directory (`FakePrp`); nothing here reaches
/// the operator's `~/.prp`. The session has no surface, so the click is the path ghostty matched
/// with no rows around it; joining wrapped rows is `TerminalStorePathTests`'.
@MainActor
final class TerminalStoreLinkTests: XCTestCase {
    private var prp: FakePrp!
    private var rig: ToyRig!
    private var session: TerminalSession!
    private var store: URL!

    override func setUpWithError() throws {
        prp = try FakePrp()
        store = try prp.store("helm-3ec376fc", path: nil)
    }

    /// helm on a toy benchd that knows `prp`, and a terminal session on its bench.
    private func mount() throws {
        rig = try toyRig()
        rig.server.answer = rig.server.answeringPrp(prp, else: rig.server.answer)
        session = TerminalSession(
            ordinal: 1, workspacePath: WorkspacePath(NSTemporaryDirectory()),
            controller: TerminalSession.makeController(userConfig: nil))
        session.manager = rig.terminals
    }

    override func tearDownWithError() throws {
        prp.remove()
    }

    private func file(_ relative: String, in dir: URL) throws -> String {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# report\n".utf8).write(to: url)
        return url.path
    }

    private func asked(_ verb: String) -> Bool {
        rig.server.requests.contains { $0["verb"] as? String == verb }
    }

    private var opened: [String: Any]? {
        rig.server.verbs.last { $0["verb"] as? String == "pane/open" }
    }

    /// ⌘-click `clicked` and wait for the `pane/open` it makes.
    private func clickOpens(_ clicked: String) -> [String: Any]? {
        session.terminalDidRequestOpenURL(clicked, kind: .unknown)
        Eventually.holds(within: 5) { self.opened != nil }
        return opened
    }

    /// ⌘-click `clicked`, wait until benchd has been asked about the path, then let a further
    /// half second elapse for a `pane/open` that must not come.
    private func clickOpensNothing(_ clicked: String) -> Bool {
        session.terminalDidRequestOpenURL(clicked, kind: .unknown)
        guard Eventually.holds(within: 5, { self.asked("path/resolve") }) else {
            XCTFail("control: helm never asked benchd about \(clicked)")
            return false
        }
        Eventually.holds(within: 0.5) { self.opened != nil }
        return opened == nil
    }

    func testAStorePathOpensAsACanvasPaneBesideTheTerminal() throws {
        try mount()
        let report = try file("reports/launch-queue.md", in: store)

        let sent = try XCTUnwrap(clickOpens(report), "a store file the operator clicked opens")

        let surface = (sent["args"] as? [String: Any])?["surface"] as? [String: Any]
        XCTAssertEqual(surface?["kind"] as? String, "canvas")
        XCTAssertEqual(
            (surface?["source"] as? [String: Any])?["path"] as? String, report, "benchd's path")
        XCTAssertEqual(
            (sent["by"] as? [String: Any])?["kind"] as? String, "helm",
            "it appears beside the terminal; the keyboard stays in the terminal clicked in")
        XCTAssertNil(sent["asked"])
    }

    func testAPathOutsideEveryStoreStaysDropped() throws {
        try mount()
        // Renderable and existing, but terminal output is untrusted: only the stores open.
        let elsewhere = try file("notes.md", in: prp.home)

        XCTAssertTrue(clickOpensNothing(elsewhere))
        XCTAssertTrue(asked("prp/stores"), "benchd named its stores, and this is in none")
    }

    func testAMissingStoreFileStaysDropped() throws {
        try mount()
        XCTAssertTrue(clickOpensNothing(store.appendingPathComponent("reports/gone.md").path))
    }

    func testTheFirstCandidateBenchdFindsIsTheOneOpened() async throws {
        try mount()
        let report = try file("reports/plan.md", in: store)

        let id = await rig.model.openStoreFile([report + "x.md", report])

        let pane = try XCTUnwrap(id.flatMap { rig.model.bench?.pane($0) })
        guard case let .canvas(.file(path)) = pane.content else {
            return XCTFail("a store file opens as a canvas pane")
        }
        XCTAssertEqual(path.value, report)
    }
}
