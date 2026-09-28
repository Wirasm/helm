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

    /// End to end through the client: a benchd that is not there never yields a bare `bench`.
    @MainActor
    func testAClientWithNoBenchdNeverAnswersABareName() {
        let client = BenchClient(endpoint: .unix(path: "/nonexistent/benchd.sock"))
        switch client.benchExecutable {
        case let .success(path): XCTAssertTrue(path.hasPrefix("/"), path)
        case let .failure(missing): XCTAssertTrue(missing.asked.contains("could not be asked"))
        }
    }
}
