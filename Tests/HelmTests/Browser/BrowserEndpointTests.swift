import XCTest

@testable import Helm

/// helm's reading of the file benchd writes. `daemon/fixtures/browser-endpoint.json` is the one
/// sample both sides test: the daemon's conformance suite pins what it writes to the fixture's
/// keys, and this decodes the same bytes — so a rename on either side is a red gate.
final class BrowserEndpointTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/fixtures/browser-endpoint.json")
    }

    func testTheDaemonsOwnSampleDecodes() throws {
        guard case let .found(endpoint) = BrowserEndpoint.read(at: fixture) else {
            return XCTFail("the fixture benchd's writer is pinned to did not decode")
        }
        XCTAssertEqual(endpoint.webSocketURL?.scheme, "ws")
        XCTAssertEqual(endpoint.startedAt, "2026-09-25T12:00:00Z")
    }

    func testAnEndpointFromAFormatThisBuildDoesNotKnowIsReportedNotMisread() throws {
        var json =
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        json["version"] = BrowserEndpoint.supportedVersion + 1
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("endpoint-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case let .unreadable(why) = BrowserEndpoint.read(at: url) else {
            return XCTFail("an endpoint from a newer format was accepted")
        }
        XCTAssertTrue(why.contains("v\(BrowserEndpoint.supportedVersion + 1)"), why)
        XCTAssertEqual(
            BrowserEndpoint.read(at: url.appendingPathExtension("missing")), .absent,
            "no file is the ordinary state: no browser running")
    }

    /// `bench_wire::resolve_root`, spelled again: BENCH_DIR wins, then the suite, then ~/.bench.
    func testTheBenchRootIsResolvedByTheDaemonsRule() {
        let home = URL(fileURLWithPath: "/Users/op")
        XCTAssertEqual(
            try BenchRoot.resolve(environment: ["BENCH_DIR": "/r", "BENCH_SUITE": "x"], home: home)
                .get().path,
            "/r")
        XCTAssertEqual(
            try BenchRoot.resolve(environment: ["BENCH_SUITE": "dev"], home: home).get().path,
            "/Users/op/.bench-dev")
        XCTAssertEqual(
            try BenchRoot.resolve(environment: [:], home: home).get().path, "/Users/op/.bench")
        for bad in ["", "a/b", "UP", "-x", String(repeating: "x", count: 33)] {
            XCTAssertThrowsError(
                try BenchRoot.resolve(environment: ["BENCH_SUITE": bad], home: home).get(),
                "\(bad) cannot isolate, and must not fall back to the shared ~/.bench")
        }
        XCTAssertThrowsError(
            try BenchRoot.resolve(
                environment: ["BENCH_DIR": "/r", "BENCH_SUITE": "a/b"], home: home
            )
            .get(), "bench refuses the suite before BENCH_DIR can win")
    }
}
