import XCTest

@testable import Helm

final class HelmBenchDirectoryTests: XCTestCase {
    private var directory: HelmBenchDirectory!

    override func setUpWithError() throws {
        directory = HelmBenchDirectory(
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
            HelmBenchDirectory.resolve(environment: [:], home: home).root.path,
            "/Users/nobody/.helm/bench")
        XCTAssertEqual(
            HelmBenchDirectory.resolve(
                environment: ["HELM_DEFAULTS_SUITE": "helm-test"], home: home
            ).root.path,
            "/Users/nobody/.helm/bench-helm-test")
        XCTAssertEqual(
            HelmBenchDirectory.resolve(
                environment: ["HELM_BENCH_DIR": "/tmp/target", "HELM_DEFAULTS_SUITE": "x"],
                home: home
            ).root.path,
            "/tmp/target")
    }

    /// The keymap sits beside the snapshot, so an isolated helm has its own (M5c).
    func testTheKeymapIsInTheSameDirectory() {
        let home = URL(fileURLWithPath: "/Users/nobody")
        XCTAssertEqual(
            HelmBenchDirectory.resolve(environment: [:], home: home).keymap.path,
            "/Users/nobody/.helm/bench/keymap.toml")
        XCTAssertEqual(
            HelmBenchDirectory.resolve(environment: ["HELM_DEFAULTS_SUITE": "t"], home: home)
                .keymap.path,
            "/Users/nobody/.helm/bench-t/keymap.toml")
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

    func testConcurrentReadersOnlyObserveCompleteSnapshots() {
        let directory = directory!
        let failures = Atomic()
        let start = DispatchGroup()
        let finished = DispatchGroup()
        start.enter()

        for _ in 0..<4 {
            finished.enter()
            DispatchQueue.global().async { [directory] in
                start.wait()
                defer { finished.leave() }
                for _ in 0..<250 {
                    if FileManager.default.fileExists(atPath: directory.snapshot.path),
                        directory.read() == nil
                    {
                        failures.increment()
                    }
                }
            }
        }

        finished.enter()
        DispatchQueue.global().async { [directory] in
            start.leave()
            defer { finished.leave() }
            for second in 0..<250 {
                let value = BenchSnapshot(
                    writtenAt: Date(timeIntervalSince1970: TimeInterval(second)), workspaces: [])
                if !directory.write(value) {
                    failures.increment()
                }
            }
        }

        finished.wait()
        XCTAssertEqual(failures.value, 0)
    }

    private func permissions(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}

private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
