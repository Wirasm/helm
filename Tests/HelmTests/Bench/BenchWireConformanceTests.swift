import Foundation
import HelmWire
import XCTest

/// helm's copy of benchd's wire types against the daemon's own samples in `daemon/fixtures/`.
/// The daemon gate pins those same files byte for byte against the Rust types, so a field renamed
/// on either side turns one gate or the other red. This is the #352/#353 pattern
/// (`browser-endpoint.json`): neither gate needs the other's toolchain.
///
/// **Compared as values, never as bytes.** Swift writes UUIDs in uppercase and Rust in lowercase,
/// and key order differs by encoder; neither is a difference the daemon sees.
final class BenchWireConformanceTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    /// The JSON as plain objects, with every UUID lowercased — the normal form both sides agree on.
    private func normalized(_ data: Data) throws -> NSObject {
        func walk(_ value: Any) -> Any {
            switch value {
            case let dict as [String: Any]: return dict.mapValues(walk)
            case let list as [Any]: return list.map(walk)
            case let text as String where UUID(uuidString: text) != nil: return text.lowercased()
            default: return value
            }
        }
        return walk(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
            as! NSObject
    }

    func testTheDocumentFixtureDecodesAndReEncodesToTheSameValue() throws {
        let data = try fixture("bench-document.json")
        let document = try JSONDecoder().decode(BenchDocument.self, from: data)

        XCTAssertEqual(document.workspaces.count, 3)
        XCTAssertNotNil(document.active)
        XCTAssertTrue(document.workspaces.contains { $0.shelved != nil })
        let surfaces = document.workspaces.flatMap { $0.bench.columns }.flatMap(\.slots)
            .flatMap(\.panes).map(\.surface)
        XCTAssertTrue(surfaces.contains(.browser))
        XCTAssertTrue(surfaces.contains { if case .canvas = $0 { true } else { false } })
        XCTAssertTrue(surfaces.contains { if case .terminal(.some) = $0 { true } else { false } })
        XCTAssertFalse(
            surfaces.contains { if case .unsupported = $0 { true } else { false } },
            "every kind in the daemon's own sample is one helm knows")

        XCTAssertEqual(
            try normalized(JSONEncoder().encode(document)), try normalized(data),
            "helm writes back exactly what it read")
    }

    func testEveryVerbRequestMatchesTheDaemonsSample() throws {
        let data = try fixture("bench-verbs.json")
        let requests = try JSONDecoder().decode([BenchRequest].self, from: data)
        let samples = try JSONSerialization.jsonObject(with: data) as! [Any]

        XCTAssertEqual(requests.count, samples.count)
        for (request, sample) in zip(requests, samples) {
            let written = try normalized(JSONEncoder().encode(request))
            let expected = try normalized(JSONSerialization.data(withJSONObject: sample))
            XCTAssertEqual(
                written, expected, "\(request.verb.name) is written as the daemon reads it")
        }
    }

    /// Every verb helm has is in the daemon's sample, so none can go untested against it.
    func testTheSampleCoversEveryVerbHelmCanSend() throws {
        let requests = try JSONDecoder().decode(
            [BenchRequest].self, from: fixture("bench-verbs.json"))
        let sampled = Set(requests.map(\.verb.name))
        let helmSends: Set<String> = [
            "bench/get", "workspace/open", "workspace/close", "workspace/activate",
            "workspace/reset", "workspace/unshelve", "workspace/import", "pane/open",
            "pane/split", "pane/close", "pane/show", "pane/move", "pane/name", "pane/record",
            "focus/slot", "focus/step", "layout/resize",
        ]
        XCTAssertEqual(sampled, helmSends)
    }

    func testTheRepliesAndTheFrameDecode() throws {
        let replies =
            try JSONSerialization.jsonObject(with: fixture("bench-report.json"))
            as! [String: Any]
        let report = try JSONDecoder().decode(
            LayoutReport.self, from: JSONSerialization.data(withJSONObject: replies["report"]!))
        let at = try JSONDecoder().decode(
            DocumentAt.self, from: JSONSerialization.data(withJSONObject: replies["get"]!))
        XCTAssertNotNil(report.paneCreated)
        XCTAssertEqual(report.focusedPaneBefore, report.focusedPaneAfter)
        XCTAssertFalse(at.document.workspaces.isEmpty)

        let frame = try JSONDecoder().decode(BenchFrame.self, from: fixture("bench-frame.json"))
        XCTAssertEqual(frame.event.kind, "bench/changed")
        XCTAssertNotNil(frame.document)
    }

    /// A kind helm does not know is kept as `unsupported`, never dropped: the daemon owns the pane.
    func testASurfaceKindThisBuildDoesNotKnowIsKeptNotDropped() throws {
        let pane = """
            {"id":"00000009-0000-4000-8000-000000000009","surface":{"kind":"whiteboard"}}
            """
        let decoded = try JSONDecoder().decode(BenchDocument.Pane.self, from: Data(pane.utf8))
        XCTAssertEqual(decoded.surface, .unsupported(kind: "whiteboard"))

        let oldCanvas = #"{"kind":"canvas","source":{"kind":"url","url":"http://x"}}"#
        XCTAssertEqual(
            try JSONDecoder().decode(Surface.self, from: Data(oldCanvas.utf8)),
            .unsupported(kind: "canvas/url"))
    }
}
