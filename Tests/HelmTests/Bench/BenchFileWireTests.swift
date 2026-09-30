import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The canvas's file verbs (M5c) against `daemon/fixtures/file-verbs.json`, which the daemon gate
/// holds to `bench_wire::files`: a field renamed on either side turns one of the two red.
final class BenchFileWireTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    private func plain(_ data: Data) throws -> NSObject {
        try JSONSerialization.jsonObject(with: data) as! NSObject
    }

    /// `file-verbs.json` pins the canvas's file verbs (M5c): each request helm sends encodes to
    /// the fixture's, each answer and the `file/changed` frame decode, and the sidecar rule benchd
    /// watches by is the one `CanvasNotes` writes by.
    func testTheFileVerbsAreSpelledAsTheDaemonSpellsThem() throws {
        let samples =
            try JSONSerialization.jsonObject(with: fixture("file-verbs.json")) as! [String: Any]
        func sample(_ key: String) throws -> NSObject {
            try plain(JSONSerialization.data(withJSONObject: XCTUnwrap(samples[key])))
        }
        let requests: [(String, any Encodable)] = [
            (
                "read",
                BenchFileReadRequest(id: "helm-files-1", path: "/Users/op/.prp/helm/plans/plan.md")
            ),
            (
                "read_sibling",
                BenchFileReadRequest(
                    id: "helm-files-2",
                    path: "/Users/op/.prp/helm/canvas/board/vendor/board-core.js",
                    within: "/Users/op/.prp/helm/canvas/board")
            ),
            (
                "write",
                BenchFileWriteRequest(
                    id: "helm-files-3", path: "/Users/op/.prp/helm/plans/plan.md",
                    text: "# Plan\n\nMine.\n", expect: .unchanged("# Plan\n"))
            ),
            (
                "write_latch",
                BenchFileWriteRequest(
                    id: "helm-files-4", path: "/Users/op/.prp/helm/canvas/board.state.json",
                    text: "{\n  \"format\" : \"helm.canvas-state\"\n}", expect: .any)
            ),
            (
                "append",
                BenchFileAppendRequest(
                    id: "helm-files-5", path: "/Users/op/.prp/helm/plans/plan.notes.md",
                    text: "## \"Mine.\"\n\nShorter.\n\n")
            ),
        ]
        for (key, request) in requests {
            XCTAssertEqual(try plain(JSONEncoder().encode(request)), try sample(key), key)
        }

        let reads = try JSONDecoder().decode(
            [BenchFileRead].self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(samples["read_answers"])))
        XCTAssertEqual(reads, [.bytes(Data("# Plan\n".utf8)), .absent, .outside])
        let writes = try JSONDecoder().decode(
            [BenchFileWrite].self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(samples["write_answers"])))
        XCTAssertEqual(writes, [.written, .changed(Data("# Theirs\n".utf8))])
        let frame = try JSONDecoder().decode(
            BenchEventFrame<BenchFileChanged>.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(samples["changed"])))
        XCTAssertEqual(frame.event.kind, BenchFileChanged.kind)
        XCTAssertEqual(frame.event.data.path, "/Users/op/.prp/helm/plans/plan.md")

        let rows = try XCTUnwrap(samples["sidecars"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let canvas = URL(fileURLWithPath: try XCTUnwrap(row["canvas"] as? String))
            XCTAssertEqual(CanvasNotes.sidecarURL(for: canvas).path, row["sidecar"] as? String)
            XCTAssertEqual(CanvasNotes.isSidecar(canvas), row["canvas_is_sidecar"] as? Bool)
        }
    }
}
