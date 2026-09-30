import Foundation
import HelmWire
import XCTest

@testable import Helm

/// A canvas against a real benchd reached only over TCP, whose folder this process cannot read
/// (M5c, #459): it opens, edits, conflicts, annotates, latches state and serves a page's
/// siblings, with every byte going through benchd.
///
/// **Skipped unless a harness sets it up**, because the Swift gate needs no benchd: a benchd with
/// `BENCH_LISTEN`, a canvas folder holding `plan.md` (`# Plan\n`), `page.html` and `img/x.png`,
/// `plan.md` opened on its bench (`bench open`, so benchd watches it), and this test run where the
/// folder is unreadable — under `sandbox-exec` denying it — with an empty `BENCH_DIR`.
/// `HELM_REMOTE_BENCH_URL` and `HELM_REMOTE_CANVAS_DIR` name the two. `HELM_REMOTE_FILES=disk`
/// runs it with the canvas reading its own disk instead, which is the behaviour before M5c and
/// what the red run uses.
@MainActor
final class CanvasOverTCPTests: XCTestCase {
    private var endpoint: BenchEndpoint!
    private var folder: URL!
    private var files: (any CanvasFiles)!
    private var client: BenchClient!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HELM_REMOTE_BENCH_URL"], let dir = env["HELM_REMOTE_CANVAS_DIR"]
        else { throw XCTSkip("needs a benchd over TCP (see the header)") }
        endpoint = try BenchRoot.endpoint(environment: ["BENCH_URL": url]).get()
        folder = URL(fileURLWithPath: dir)
        client = BenchClient(endpoint: endpoint)
        files =
            env["HELM_REMOTE_FILES"] == "disk"
            ? DiskCanvasFiles() : BenchCanvasFiles(client: client)
    }

    override func tearDown() {
        client?.stop()
    }

    /// Read through benchd whatever the canvas used, so the assertion is about benchd's disk.
    private func onBenchd(_ name: String) -> String? {
        guard
            case let .bytes(data) = BenchCanvasFiles(client: client)
                .read(folder.appendingPathComponent(name).path, within: nil)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func eventually(_ what: String, _ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done() {
            guard ContinuousClock.now < deadline else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testACanvasOpensEditsConflictsAndAnnotatesThroughBenchdAlone() async throws {
        let plan = folder.appendingPathComponent("plan.md")
        XCTAssertNil(
            try? Data(contentsOf: plan), "precondition: this process cannot read the folder")
        let model = CanvasModel(source: .file(plan), files: files, saveDebounce: .seconds(30))
        // benchd's follower, as the workbench wires it: its `file/changed` reaches the canvas.
        client.onEvent = { [weak model] line in
            guard
                let frame = try? JSONDecoder().decode(
                    BenchEventFrame<BenchFileChanged>.self, from: line),
                frame.event.kind == BenchFileChanged.kind
            else { return }
            model?.fileChanged(frame.event.data.path)
        }
        client.start()

        // Opens.
        guard case .markdown("# Plan\n") = model.showing?.content else {
            return XCTFail(
                "the canvas did not render: \(String(describing: model.showing?.content))")
        }

        // Edits, and the save lands on benchd's disk.
        model.write()
        XCTAssertNotNil(model.draft)
        model.edit("# Plan\n\nMine.\n")
        model.saveDraft()
        XCTAssertNil(model.writeFailure)
        XCTAssertEqual(onBenchd("plan.md"), "# Plan\n\nMine.\n")

        // An agent rewrites it under a dirty draft: benchd reports it, the strip goes up, and a
        // save writes nothing over theirs.
        model.edit("# Plan\n\nMine, longer.\n")
        _ = BenchCanvasFiles(client: client).write("# Theirs\n", to: plan.path, expect: .any)
        try await eventually("the conflict strip") { model.draft?.conflict != nil }
        model.saveDraft()
        XCTAssertEqual(onBenchd("plan.md"), "# Theirs\n", "nothing written over bytes not shown")

        // Keep mine.
        model.keepMine()
        XCTAssertNil(model.draft?.conflict)
        XCTAssertEqual(onBenchd("plan.md"), "# Plan\n\nMine, longer.\n")
        model.read()

        // Annotates: the sidecar grows on benchd's side, and the drawer reads it back.
        model.pageDidReport(
            try CanvasPageSelection.decode(["kind": "selection", "text": "Mine, longer."]).get())
        model.annotate(comment: "Shorter.")
        XCTAssertNil(model.notesFailure)
        XCTAssertTrue(onBenchd("plan.notes.md")?.contains("Shorter.") == true)
        XCTAssertEqual(model.notes.count, 1)
    }

    func testAnHTMLCanvasGetsItsSiblingsAndLatchesItsState() throws {
        let page = folder.appendingPathComponent("page.html")
        XCTAssertNotNil(files.document(page), "the page itself")
        XCTAssertEqual(
            files.read(folder.appendingPathComponent("img/x.png").path, within: folder.path),
            .bytes(Data([0x89, 0x50, 0x4E, 0x47])))
        XCTAssertEqual(
            files.read(folder.path + "/../outside.txt", within: folder.path), .outside)

        let model = CanvasModel(source: .file(page), files: files)
        guard
            case let .success(report) = CanvasPageState.decode([
                "kind": "canvas.state", "state": ["level": 3],
            ])
        else { return XCTFail("a state the page may report") }
        model.pageDidReportState(report)
        XCTAssertTrue(onBenchd("page.state.json")?.contains("\"level\" : 3") == true)
    }
}
