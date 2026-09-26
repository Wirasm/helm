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

        // Drawers (#356): one open, one closed and badged.
        let open = try XCTUnwrap(document.drawers.first { $0.name == document.openDrawer })
        XCTAssertGreaterThan(open.panes.count, 1)
        XCTAssertTrue(document.drawers.contains { $0.badged && $0.name != open.name })

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
            "focus/slot", "focus/step", "layout/resize", "drawer/toggle",
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

    /// The two mail verbs helm sends benchd (#358), and the answer to `who` — the canvas note's
    /// route and a spawn's handle both hang off these.
    func testTheMailRequestsMatchTheDaemonsSampleAndTheWhoReplyDecodes() throws {
        let data = try fixture("mail-verbs.json")
        let samples = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func sample(_ key: String) throws -> NSObject {
            try normalized(JSONSerialization.data(withJSONObject: XCTUnwrap(samples[key])))
        }

        let who = BenchMailRequest.who(
            id: "helm-1", pane: UUID(uuidString: "0e8e8cc6-159b-45d8-bc02-485120975998")!)
        XCTAssertEqual(try normalized(JSONEncoder().encode(who)), try sample("who"))

        let send = BenchMailRequest.send(
            id: "helm-2", to: Handle(validating: "helm-a1b2")!, from: "operator",
            subject: "note on plan.md", body: "> the quoted line\n\nthe operator's note")
        XCTAssertEqual(try normalized(JSONEncoder().encode(send)), try sample("send"))

        let reply = try JSONDecoder().decode(
            BenchMailWho.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(samples["who_reply"])))
        XCTAssertEqual(
            reply,
            BenchMailWho(
                handle: Handle(validating: "helm-a1b2")!, harness: "claude",
                session: "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2"))
    }

    /// A document written before drawers existed has none, and helm writes none back.
    func testADocumentWithoutDrawersReadsAndWritesWithout() throws {
        let data = Data(#"{"workspaces":[],"active":null}"#.utf8)
        let document = try JSONDecoder().decode(BenchDocument.self, from: data)
        XCTAssertEqual(document.drawers, [])
        XCTAssertNil(document.openDrawer)
        let written = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        XCTAssertFalse(written.contains("drawer"), written)
    }

    /// benchd refuses a `pane/open` naming a workspace and a drawer, and reads a null as absent;
    /// helm's decode draws the same line.
    func testPaneOpenNamesAWorkspaceOrADrawerNeverBoth() throws {
        func decode(_ args: String) throws -> BenchVerb {
            let line = #"{"id":"x","verb":"pane/open","args":"# + args + "}"
            return try JSONDecoder().decode(BenchRequest.self, from: Data(line.utf8)).verb
        }
        let browser = #""surface":{"kind":"browser"}"#
        XCTAssertEqual(
            try decode(#"{"drawer":"notes","workspace":null,"# + browser + "}"),
            .paneOpenInDrawer("notes", surface: .browser))
        XCTAssertThrowsError(
            try decode(#"{"drawer":"notes","workspace":"/tmp/w","# + browser + "}"))
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

    /// `bench-root.json` is the table `bench_wire::resolve_root` is checked against in the daemon
    /// gate, so `BenchRoot` and the Rust rule answer every row the same way or one gate goes red.
    /// It holds only `BENCH_DIR` and `BENCH_SUITE`, the variables `bench` reads. An empty
    /// `BENCH_DIR` is the row that disagreed until #395.
    func testTheBenchRootTableResolvesAsTheDaemonResolvesIt() throws {
        struct Table: Decodable {
            struct Row: Decodable {
                let env: [String: String]
                let root: String?
                let refused: String?
            }
            let home: String
            let rows: [Row]
        }
        let table = try JSONDecoder().decode(Table.self, from: fixture("bench-root.json"))
        let home = URL(fileURLWithPath: table.home, isDirectory: true)
        for row in table.rows {
            switch BenchRoot.resolve(environment: row.env, home: home) {
            case .success(let root):
                XCTAssertEqual(root.path, row.root, "\(row.env)")
            case .failure(let error):
                XCTAssertEqual(error.variable, row.refused, "\(row.env)")
            }
        }
    }
}
