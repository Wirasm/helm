import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The live file (#532) on helm's side: what a page's write may say, what helm sends benchd for
/// it, and when a change to the file is offered back to the page. benchd's compare, watcher and
/// mail are the daemon gate's (`conformance.rs`, `benchd/src/live.rs`); the WebKit join is
/// `CanvasLiveFileLiveTests`.
@MainActor
final class LiveFileTests: XCTestCase {
    private var directory: URL!
    private var page: URL!
    private var data: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-live-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        page = directory.appendingPathComponent("tasks.html")
        data = directory.appendingPathComponent("tasks.data.json")
        try "<p>tasks</p>".write(to: page, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The disk, recording every write helm asked for.
    private final class Recording: CanvasFiles, @unchecked Sendable {
        var writes: [(path: String, notify: Bool)] = []
        func read(_ path: String, within folder: String?) -> CanvasFileRead {
            DiskCanvasFiles().read(path, within: folder)
        }
        func write(
            _ text: String, to path: String, expect: BenchFileExpect, notify: Bool
        )
            -> CanvasFileWrite
        {
            writes.append((path, notify))
            return DiskCanvasFiles().write(text, to: path, expect: expect, notify: notify)
        }
        func append(_ text: String, to path: String) throws {
            try DiskCanvasFiles().append(text, to: path)
        }
    }

    private func write(
        _ data: Any, base: Any = NSNull(), notify: Bool? = nil
    ) throws
        -> CanvasDataWrite
    {
        var body: [String: Any] = ["kind": CanvasDataWrite.kind, "data": data, "base": base]
        if let notify { body["notify"] = notify }
        return try CanvasDataWrite.decode(body).get()
    }

    private func onDisk() throws -> String { try String(contentsOf: data, encoding: .utf8) }

    // MARK: - What a page may say

    func testAWriteIsJSONWithSortedKeysAndNotifiesUnlessItSaysNot() throws {
        let write = try write(["b": 1, "a": ["x/y"]])
        XCTAssertEqual(write.text, "{\n  \"a\" : [\n    \"x/y\"\n  ],\n  \"b\" : 1\n}\n")
        XCTAssertNil(write.base)
        XCTAssertTrue(write.notify)
        XCTAssertFalse(try self.write([1], base: "[]", notify: false).notify)
    }

    /// Refused rather than guessed at: a page's bug is named, never rounded to a write.
    func testWhatIsNotAWriteIsRefusedByName() {
        func refusal(_ body: Any) -> CanvasDataWrite.Refusal? {
            if case let .failure(refusal) = CanvasDataWrite.decode(body) { return refusal }
            return nil
        }
        XCTAssertEqual(refusal("hello"), .notAnObject)
        XCTAssertEqual(
            refusal(["kind": "canvas.state", "state": [:]]), .unknownKind("canvas.state"))
        XCTAssertEqual(
            refusal(["kind": CanvasDataWrite.kind, "data": [:]]), .noBase,
            "a write that names no base would be a blind write")
        XCTAssertEqual(
            refusal(["kind": CanvasDataWrite.kind, "data": 42, "base": NSNull()]), .notJSON)
        XCTAssertEqual(
            refusal(["kind": CanvasDataWrite.kind, "data": ["n": Double.nan], "base": NSNull()]),
            .notJSON)
    }

    // MARK: - The write

    func testAPageWriteLandsInTheFileBesideTheCanvasAndSaysWhetherToNotify() throws {
        let files = Recording()
        let model = CanvasModel(source: .file(page), files: files)

        let answer = model.pageWroteData(try write(["done": true], notify: false))
        XCTAssertEqual(answer, .success(.written("{\n  \"done\" : true\n}\n")))
        XCTAssertEqual(try onDisk(), "{\n  \"done\" : true\n}\n")
        XCTAssertEqual(files.writes.map(\.path), [data.path])
        XCTAssertEqual(files.writes.map(\.notify), [false])
    }

    /// **Nobody's write replaces a version its writer has not seen.** The agent wrote since the
    /// page read; the page is handed the agent's bytes and the file keeps them.
    func testAStaleWriteIsAnsweredWithTheFileAndWritesNothing() throws {
        let model = CanvasModel(source: .file(page), files: DiskCanvasFiles())
        try "{\"done\": false, \"by\": \"agent\"}".write(
            to: data, atomically: true, encoding: .utf8)

        let answer = model.pageWroteData(try write(["done": true], base: "{\"done\": false}"))
        XCTAssertEqual(answer, .success(.changed("{\"done\": false, \"by\": \"agent\"}")))
        XCTAssertEqual(try onDisk(), "{\"done\": false, \"by\": \"agent\"}")
    }

    /// A page whose base is stale is told so even when it writes its own base back: helm asks
    /// benchd rather than answering `written` from the page's say-so.
    func testWritingBackAStaleBaseIsAnsweredWithTheNewerFile() throws {
        let model = CanvasModel(source: .file(page), files: DiskCanvasFiles())
        let mine = try write(["done": true]).text
        try "{\"done\": false}".write(to: data, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            model.pageWroteData(try write(["done": true], base: mine)),
            .success(.changed("{\"done\": false}")))
    }

    func testOnlyAnHTMLCanvasHasALiveFile() throws {
        let plan = directory.appendingPathComponent("plan.md")
        try "# Plan\n".write(to: plan, atomically: true, encoding: .utf8)
        let model = CanvasModel(source: .file(plan), files: DiskCanvasFiles())
        XCTAssertNil(model.liveFile)
        guard case .failure = model.pageWroteData(try write(["x": 1])) else {
            return XCTFail("a markdown canvas has no live file to write")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("plan.data.json").path))
    }

    // MARK: - Offered back

    /// The page's own write coming back from benchd's watcher is not news; the agent's write is,
    /// and it names the live file. A change to the artifact names the artifact.
    func testAnAgentsWriteIsOfferedNamingTheFileAndThePagesOwnIsNot() throws {
        let model = CanvasModel(source: .file(page), files: DiskCanvasFiles())
        _ = model.pageWroteData(try write(["done": true]))
        model.fileChanged(data.path)
        XCTAssertEqual(model.showing?.generation, 0)

        try "{\"done\": false}".write(to: data, atomically: true, encoding: .utf8)
        model.fileChanged(data.path)
        XCTAssertEqual(model.showing?.generation, 1)
        XCTAssertEqual(model.showing?.changed, "tasks.data.json")
        model.fileChanged(data.path)
        XCTAssertEqual(model.showing?.generation, 1, "the same bytes again are not a change")

        try "<p>tasks, rewritten</p>".write(to: page, atomically: true, encoding: .utf8)
        model.fileChanged(page.path)
        XCTAssertEqual(model.showing?.generation, 2)
        XCTAssertEqual(model.showing?.changed, "tasks.html")
    }

    /// A change made while benchd's follower was down reaches the page on the reconnect's re-read.
    func testAReReadOffersALiveFileChangedWhileNobodyWasListening() throws {
        let model = CanvasModel(source: .file(page), files: DiskCanvasFiles())
        try "{\"done\": false}".write(to: data, atomically: true, encoding: .utf8)
        model.reread()
        XCTAssertEqual(model.showing?.generation, 1)
        XCTAssertEqual(model.showing?.changed, "tasks.data.json")
    }

    func testTheUpdateOfferCarriesTheFileThatChanged() throws {
        let offer = CanvasUpdate(artifact: page, generation: 3, file: "tasks.data.json")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(offer))
        XCTAssertEqual((json as? [String: Any])?["file"] as? String, "tasks.data.json")
        XCTAssertEqual(CanvasUpdate(artifact: page, generation: 1).file, "tasks.html")
    }
}
