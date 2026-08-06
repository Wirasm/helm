import XCTest

@testable import Helm

final class BenchSnapshotDirectoryTests: XCTestCase {
    private var directory: BenchSnapshotDirectory!

    override func setUpWithError() throws {
        directory = BenchSnapshotDirectory(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("helm-bench-directory-\(UUID().uuidString)"))
        try directory.prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.root)
        directory = nil
    }

    func testDefaultSuiteAndExplicitPathsDoNotCollide() {
        let home = URL(fileURLWithPath: "/Users/nobody")
        XCTAssertEqual(
            BenchSnapshotDirectory.resolve(environment: [:], home: home).root.path,
            "/Users/nobody/.helm/bench")
        XCTAssertEqual(
            BenchSnapshotDirectory.resolve(
                environment: ["HELM_DEFAULTS_SUITE": "helm-test"], home: home
            ).root.path,
            "/Users/nobody/.helm/bench-helm-test")
        XCTAssertEqual(
            BenchSnapshotDirectory.resolve(
                environment: ["HELM_BENCH_DIR": "/tmp/target", "HELM_DEFAULTS_SUITE": "x"],
                home: home
            ).root.path,
            "/tmp/target")
    }

    func testWriteIsPrivatePrettySortedAndDecodable() throws {
        let value = BenchSnapshot(
            writtenAt: Date(timeIntervalSince1970: 1_700_000_000), workspaces: [])
        XCTAssertTrue(directory.write(value))

        XCTAssertEqual(directory.read(), value)
        let text = try String(contentsOf: directory.snapshot, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), text)
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "\"format\"")).lowerBound,
            try XCTUnwrap(text.range(of: "\"version\"")).lowerBound)
        XCTAssertEqual(permissions(directory.root), 0o700)
        XCTAssertEqual(permissions(directory.snapshot), 0o600)
    }

    func testEveryReadAcrossRepeatedAtomicReplacementsIsComplete() throws {
        for second in 0..<200 {
            let value = BenchSnapshot(
                writtenAt: Date(timeIntervalSince1970: TimeInterval(second)), workspaces: [])
            XCTAssertTrue(directory.write(value))
            XCTAssertEqual(directory.read(), value)
        }
    }

    private func permissions(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}
