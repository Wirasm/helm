import Foundation
import HelmWire
import XCTest

@testable import Helm

/// A canvas's files go through benchd (M5c, #459): what helm does when benchd cannot be asked, how
/// benchd's `file/changed` reaches the right canvas, and that `BenchCanvasFiles` speaks the wire.
///
/// benchd's own rules (the folder boundary, the compare-and-write, the sidecar refusal) are the
/// daemon gate's, over TCP against the real binary; these are helm's side.
@MainActor
final class CanvasThroughBenchdTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-canvas-benchd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The disk, until the test says benchd stopped answering.
    private final class Reachable: CanvasFiles, @unchecked Sendable {
        var down = false
        private var files: DiskCanvasFiles {
            DiskCanvasFiles(failing: down ? "benchd is not answering" : nil)
        }
        func read(_ path: String, within folder: String?) -> CanvasFileRead {
            files.read(path, within: folder)
        }
        func write(_ text: String, to path: String, expect: BenchFileExpect) -> CanvasFileWrite {
            files.write(text, to: path, expect: expect)
        }
        func append(_ text: String, to path: String) throws { try files.append(text, to: path) }
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - benchd cannot be asked

    /// **The clobber the spike named.** An unreachable benchd must not read as an absent file, or
    /// the editor would open empty and autosave nothing over the plan.
    func testTheEditorDoesNotOpenOverAFileBenchdCouldNotRead() throws {
        let plan = try file("plan.md", "# Plan\n")
        let files = Reachable()
        let model = CanvasModel(source: .file(plan), files: files, saveDebounce: .seconds(30))
        files.down = true

        model.write()

        XCTAssertNil(model.draft, "no editor over bytes helm could not read")
        XCTAssertNotNil(model.writeFailure)
        XCTAssertEqual(try String(contentsOf: plan, encoding: .utf8), "# Plan\n")
    }

    /// A save benchd could not be asked for writes nothing, says why, and keeps every character
    /// for the next try — which succeeds once benchd answers again.
    func testASaveBenchdCouldNotTakeKeepsTheDraftAndSavesLater() throws {
        let plan = try file("plan.md", "# Plan\n")
        let files = Reachable()
        let model = CanvasModel(source: .file(plan), files: files, saveDebounce: .seconds(30))
        model.write()
        model.edit("# Plan\n\nMine.\n")
        files.down = true

        model.saveDraft()

        XCTAssertEqual(try String(contentsOf: plan, encoding: .utf8), "# Plan\n")
        XCTAssertEqual(model.draft?.text, "# Plan\n\nMine.\n")
        XCTAssertEqual(model.draft?.isDirty, true)
        XCTAssertTrue(model.writeFailure?.contains("benchd is not answering") == true)

        files.down = false
        model.saveDraft()

        XCTAssertEqual(try String(contentsOf: plan, encoding: .utf8), "# Plan\n\nMine.\n")
        XCTAssertNil(model.writeFailure)
    }

    func testACanvasBenchdCouldNotReadSaysWhy() throws {
        let plan = try file("plan.md", "# Plan\n")
        let model = CanvasModel(
            source: .file(plan), files: DiskCanvasFiles(failing: "benchd is not answering"))

        guard case let .notice(message) = model.showing?.content else {
            return XCTFail("a canvas benchd could not read is a notice")
        }
        XCTAssertTrue(message.contains("benchd is not answering"), message)
    }

    // MARK: - benchd says a file changed

    /// The artifact's change reloads it (a generation bump, which is also what offers an `.html`
    /// page its update rather than reloading it); the sidecar's only re-reads the notes; anything
    /// else is somebody else's.
    func testAChangeReachesOnlyTheCanvasItNames() throws {
        let plan = try file("plan.md", "# Plan\n")
        let model = CanvasModel(source: .file(plan))
        let first = try XCTUnwrap(model.showing?.generation)

        _ = try file("other.md", "unrelated")
        model.fileChanged(directory.appendingPathComponent("other.md").path)
        XCTAssertEqual(model.showing?.generation, first, "another file's change is not this one's")

        _ = try file("plan.notes.md", "## a note\n")
        model.fileChanged(directory.appendingPathComponent("plan.notes.md").path)
        XCTAssertEqual(model.showing?.generation, first, "a note is not an edit to the page")
        XCTAssertEqual(model.notes, ["a note"])

        _ = try file("plan.md", "# Plan\n\nRewritten.\n")
        // benchd's spelling of the path, which helm compares after standardizing.
        model.fileChanged(directory.path + "/./plan.md")
        XCTAssertEqual(model.showing?.generation, first + 1)
        guard case let .markdown(text) = model.showing?.content else {
            return XCTFail("still a markdown canvas")
        }
        XCTAssertEqual(text, "# Plan\n\nRewritten.\n")
    }

    /// The frame on benchd's follower reaches the canvas through the workbench, and a frame of
    /// another kind does nothing.
    func testTheFollowersFrameReachesACanvasOnTheBench() throws {
        let plan = try file("plan.md", "# Plan\n")
        let rig = try toyRig()
        rig.model.send(.paneOpen(surface: .canvas(path: plan.path)), by: .operatorGesture)
        let bench = try XCTUnwrap(rig.model.bench)
        let pane = try XCTUnwrap(bench.pane(try XCTUnwrap(bench.pane(showing: .file(plan)))))
        let canvas = rig.model.canvas(for: pane)
        let first = try XCTUnwrap(canvas.showing?.generation)
        guard case .markdown("# Plan\n") = canvas.showing?.content else {
            return XCTFail("the canvas read its file through the stand-in benchd")
        }

        rig.model.fileChanged(fileChangedFrame(plan.path).replacingKind(with: "just/finished"))
        XCTAssertEqual(canvas.showing?.generation, first)

        rig.model.fileChanged(fileChangedFrame(plan.path))
        XCTAssertEqual(canvas.showing?.generation, first + 1)
    }

    // MARK: - The wire

    /// Each answer, over TCP, decoded to what the canvas acts on — and a benchd that is gone is
    /// `failed`, never `absent`.
    func testBenchCanvasFilesSpeaksTheWireOverTCP() throws {
        let server = try FakeBenchd(
            document: DocumentAt(seq: 1, document: BenchDocument(workspaces: [], active: nil)),
            tcp: true)
        server.answer = server.answeringFiles { raw in
            ["id": raw["id"] ?? "", "status": "refused", "reason": "not a file verb"]
        }
        let client = BenchClient(endpoint: server.endpoint)
        let files = BenchCanvasFiles(client: client)
        let plan = try file("plan.md", "# Plan\n")
        let png = directory.appendingPathComponent("x.png")
        try Data([0x89, 0x50, 0x00, 0xFF]).write(to: png)

        XCTAssertEqual(files.read(plan.path, within: nil), .bytes(Data("# Plan\n".utf8)))
        XCTAssertEqual(
            files.read(png.path, within: directory.path), .bytes(Data([0x89, 0x50, 0x00, 0xFF])))
        XCTAssertEqual(
            files.read(directory.appendingPathComponent("gone.md").path, within: nil), .absent)
        XCTAssertEqual(files.read(directory.path + "/../x", within: directory.path), .outside)

        XCTAssertEqual(files.write("mine", to: plan.path, expect: .unchanged("# Plan\n")), .written)
        XCTAssertEqual(
            files.write("again", to: plan.path, expect: .unchanged("# Plan\n")),
            .changed(Data("mine".utf8)))
        XCTAssertEqual(try String(contentsOf: plan, encoding: .utf8), "mine")
        let notes = directory.appendingPathComponent("plan.notes.md")
        try files.append("## one\n", to: notes.path)
        try files.append("## two\n", to: notes.path)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "## one\n## two\n")
        guard case .failed = files.write("", to: notes.path, expect: .any) else {
            return XCTFail("a sidecar is never written whole")
        }

        server.stop()
        guard case .failed = files.read(plan.path, within: nil) else {
            return XCTFail("a benchd that is gone is not an absent file")
        }
    }
}

extension Data {
    /// A frame with its event kind swapped, for a test that needs a frame helm must ignore.
    fileprivate func replacingKind(with kind: String) -> Data {
        var object = try! JSONSerialization.jsonObject(with: self) as! [String: Any]
        var event = object["event"] as! [String: Any]
        event["kind"] = kind
        object["event"] = event
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
