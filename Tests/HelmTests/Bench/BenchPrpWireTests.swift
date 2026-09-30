import Foundation
import HelmWire
import XCTest

@testable import Helm

/// prp's stores and typed paths (M5c) against `daemon/fixtures/prp-verbs.json`, which the daemon
/// gate holds to `bench_wire::prp`: a field renamed on either side turns one of the two red.
final class BenchPrpWireTests: XCTestCase {
    private func samples() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/fixtures/prp-verbs.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func plain(_ value: Any) throws -> NSObject {
        try JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: value)) as! NSObject
    }

    private func decode<T: Decodable>(_: T.Type, _ value: Any?) throws -> T {
        try JSONDecoder().decode(
            T.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(value)))
    }

    func testThePrpVerbsAreSpelledAsTheDaemonSpellsThem() throws {
        let samples = try samples()
        let requests: [(String, BenchPrpRequest)] = [
            (
                "note",
                BenchPrpRequest(
                    id: "helm-prp-1",
                    .note(workspace: "/Users/op/Projects/helm/.worktrees/x", day: "2026-09-30"))
            ),
            (
                "stores",
                BenchPrpRequest(id: "helm-prp-2", .stores(workspace: "/Users/op/Projects/helm"))
            ),
            ("stores_all", BenchPrpRequest(id: "helm-prp-3", .stores(workspace: nil))),
            ("artifacts", BenchPrpRequest(id: "helm-prp-4", .artifacts(store: "helm-3ec376fc"))),
            ("resolve", BenchPrpRequest(id: "helm-prp-5", .resolvePath("~/Projects/helm"))),
        ]
        for (key, request) in requests {
            XCTAssertEqual(
                try plain(JSONSerialization.jsonObject(with: JSONEncoder().encode(request))),
                try plain(XCTUnwrap(samples[key])), key)
        }

        XCTAssertEqual(
            try decode(BenchPrpNote.self, samples["note_answer"]).path,
            "/Users/op/.prp/helm-3ec376fc/notes/2026-09-30-note-2.md")
        let stores = try decode(BenchPrpStores.self, samples["stores_answer"])
        XCTAssertEqual(stores.workspace, "helm-3ec376fc")
        XCTAssertEqual(
            stores.stores,
            [
                BenchPrpStore(
                    key: "helm-3ec376fc", name: "helm", path: "/Users/op/Projects/helm",
                    dir: "/Users/op/.prp/helm-3ec376fc"),
                BenchPrpStore(
                    key: "scratch", name: "scratch", path: nil, dir: "/Users/op/.prp/scratch"),
            ])
        let files = try decode(BenchPrpArtifacts.self, samples["artifacts_answer"]).files
        XCTAssertEqual(files.map(\.relative), ["plans/completed/old.plan.md", "canvas/board.html"])
        XCTAssertEqual(files.first?.modifiedMs, 1_790_000_000_000)
        XCTAssertEqual(
            try decode([BenchPathResolved].self, samples["resolve_answers"]),
            [
                BenchPathResolved(path: "/Users/op/Projects/helm", kind: .directory),
                BenchPathResolved(path: "/Users/op/.prp/helm-3ec376fc/plans/plan.md", kind: .file),
            ])
    }

    /// benchd resolves a workspace's store within `resolve_wait_ms`; helm waits longer for the
    /// verbs that do it, or a slow git would read as benchd not answering (#538 review, R1).
    func testHelmOutwaitsBenchdsResolver() throws {
        let wait = try XCTUnwrap(samples()["resolve_wait_ms"] as? Double) / 1000
        XCTAssertGreaterThan(PrpStores.resolvingTimeout, wait + 1)
    }
}
