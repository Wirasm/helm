import Foundation
import HelmWire
import XCTest

/// The spawns helm and Pocket send against `daemon/fixtures/spawn-verbs.json`, which the daemon
/// gate reads into `bench_wire::SpawnArgs`.
final class BenchSpawnWireTests: XCTestCase {
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

    /// "Ask a fork" (#535) and the drawer's resume (#621): the spawns helm sends are the ones
    /// benchd reads, and helm reads what benchd answers. The daemon gate decodes the same requests
    /// into `SpawnArgs` and checks a live fork's answer carries every key of `fork_reply`.
    func testTheSpawnRequestsAndAnswerMatchTheDaemonsFixture() throws {
        let samples =
            try JSONSerialization.jsonObject(with: fixture("spawn-verbs.json")) as! [String: Any]
        let request = BenchSpawnRequest(
            id: "helm-3", agent: "claude", cwd: "/Users/operator/Projects/helm",
            conversation: .fork(
                from: "4b1c9e0f-2a3d-4c5e-8f60-718293a4b5c6",
                prompt: "You are a fork.\n\n```text\nthe marked passage\n```\n\nWhy four retries?"
            ))
        XCTAssertEqual(
            try normalized(JSONEncoder().encode(request)),
            try normalized(JSONSerialization.data(withJSONObject: XCTUnwrap(samples["fork"]))))
        // The sessions drawer's resume of a finished row (#621).
        let resume = BenchSpawnRequest(
            id: "helm-4", agent: "codex", cwd: "/Users/operator/Projects/helm/.worktrees/oopif",
            conversation: .resume("01a0faf8-b4ca-7122-9900-1340d800117a"))
        XCTAssertEqual(
            try normalized(JSONEncoder().encode(resume)),
            try normalized(JSONSerialization.data(withJSONObject: XCTUnwrap(samples["resume"]))))

        // Pocket's start (#625): a fresh conversation with its first message, model and effort.
        let start = BenchSpawnRequest(
            id: "pocket-1", agent: "claude", cwd: "/Users/operator/Projects/prp",
            conversation: .start(prompt: "Orchestrate #625 slice 3.", model: "opus", effort: "high")
        )
        XCTAssertEqual(
            try normalized(JSONEncoder().encode(start)),
            try normalized(JSONSerialization.data(withJSONObject: XCTUnwrap(samples["start"]))))

        let reply = try JSONDecoder().decode(
            BenchSpawned.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(samples["fork_reply"])))
        XCTAssertEqual(
            reply,
            BenchSpawned(
                handle: "s7", pane: UUID(uuidString: "0e8e8cc6-159b-45d8-bc02-485120975998")!))
    }
}
