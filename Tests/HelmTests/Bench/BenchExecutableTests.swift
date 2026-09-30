import HelmWire
import XCTest

@testable import Helm

/// Which `bench` a pane runs to show a benchd session: always an absolute path, because the
/// pane's command runs in a no-profile login shell whose PATH has no `~/.cargo/bin`.
final class BenchExecutableTests: XCTestCase {
    private let home = "/Users/op"

    func testBenchdsOwnBenchWinsWhenItExists() {
        let found = BenchExecutable.resolve(
            named: "/build/target/debug/bench", why: nil, home: home, path: "/usr/bin",
            isExecutable: {
                ["/build/target/debug/bench", "/Users/op/.cargo/bin/bench"].contains($0)
            })
        XCTAssertEqual(found, .success("/build/target/debug/bench"))
    }

    /// The live failure: benchd could not be asked, and helm used to run a bare `bench`.
    func testWithNoAnswerFromBenchdAnInstalledBenchIsFoundByPath() {
        let found = BenchExecutable.resolve(
            named: nil, why: "benchd closed the connection", home: home, path: "/usr/bin:/bin",
            isExecutable: { $0 == "/Users/op/.cargo/bin/bench" })
        XCTAssertEqual(found, .success("/Users/op/.cargo/bin/bench"))
    }

    func testANameBenchdGivesThatIsNotHereFallsBackRatherThanRunningIt() {
        let found = BenchExecutable.resolve(
            named: "bench", why: nil, home: home, path: nil,
            isExecutable: { $0 == "/opt/homebrew/bin/bench" })
        XCTAssertEqual(found, .success("/opt/homebrew/bin/bench"))
    }

    func testNoBenchAnywhereIsAReasonNamingWhatWasTriedAndTheFix() throws {
        let found = BenchExecutable.resolve(
            named: nil, why: "no such file", home: home, path: "/usr/bin",
            isExecutable: { _ in false })
        guard case let .failure(missing) = found else { return XCTFail("\(found)") }
        XCTAssertEqual(
            missing.looked,
            [
                "/Users/op/.cargo/bin/bench", "/opt/homebrew/bin/bench", "/usr/local/bin/bench",
                "/usr/bin/bench",
            ])
        XCTAssertTrue(missing.description.contains("no such file"), missing.description)
        XCTAssertTrue(missing.description.contains("cargo install"), missing.description)
    }

    /// A benchd over TCP and helm's own `bench` of another version: the pane says both, and the
    /// fix, rather than attaching (M5c). The same version says nothing.
    func testAnotherBuildIsAReasonNamingBothVersionsAndTheSameBuildIsNone() throws {
        XCTAssertNil(BenchExecutable.OtherBuild(bench: "/b/bench", ours: "0.0.1", benchd: "0.0.1"))
        let other = try XCTUnwrap(
            BenchExecutable.OtherBuild(bench: "/b/bench", ours: "0.0.1", benchd: "0.0.2"))
        let reason = BenchExecutable.Unusable.otherBuild(other).description
        XCTAssertTrue(reason.contains("version 0.0.1"), reason)
        XCTAssertTrue(reason.contains("version 0.0.2"), reason)
        XCTAssertTrue(reason.contains("/b/bench"), reason)
        let old = try XCTUnwrap(
            BenchExecutable.OtherBuild(bench: "/b/bench", ours: nil, benchd: "0.0.1"))
        XCTAssertTrue(old.description.contains("version unknown"), old.description)
    }

    /// `bench --version` read off a real process: a stub script, never a system binary.
    func testTheVersionIsWhatTheBenchPrintsAndNoneWhenItFails() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-bench-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func stub(_ name: String, _ body: String) throws -> String {
            let path = dir.appendingPathComponent(name).path
            try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        let current = try stub("current", #"[ "$1" = --version ] && echo 0.0.7"#)
        let old = try stub("old", #"echo "unknown argument \"$1\"" >&2; exit 3"#)
        XCTAssertEqual(BenchExecutable.version(of: current), "0.0.7")
        XCTAssertNil(BenchExecutable.version(of: old), "a bench from before the flag")
        XCTAssertNil(BenchExecutable.version(of: dir.appendingPathComponent("absent").path))
    }

    /// End to end through the client: a benchd that is not there never yields a bare `bench`.
    @MainActor
    func testAClientWithNoBenchdNeverAnswersABareName() {
        let client = BenchClient(endpoint: .unix(path: "/nonexistent/benchd.sock"))
        switch client.benchExecutable {
        case let .success(path): XCTAssertTrue(path.hasPrefix("/"), path)
        case let .failure(.notFound(missing)):
            XCTAssertTrue(missing.asked.contains("could not be asked"))
        case let .failure(other): XCTFail("\(other)")
        }
    }
}
