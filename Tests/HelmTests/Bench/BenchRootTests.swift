import HelmWire
import XCTest

/// `BenchRoot.resolve`: benchd's rule, plus the helm suite (#378).
final class BenchRootTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/op")

    private func root(_ environment: [String: String]) -> Result<URL, BenchRootError> {
        BenchRoot.resolve(environment: environment, home: home)
    }

    /// `bench_wire::resolve_root`, spelled again: BENCH_DIR wins, then the suite, then ~/.bench.
    func testTheBenchRootIsResolvedByTheDaemonsRule() {
        XCTAssertEqual(try root(["BENCH_DIR": "/r", "BENCH_SUITE": "x"]).get().path, "/r")
        XCTAssertEqual(try root(["BENCH_SUITE": "dev"]).get().path, "/Users/op/.bench-dev")
        XCTAssertEqual(try root([:]).get().path, "/Users/op/.bench")
        for bad in ["", "a/b", "UP", "-x", String(repeating: "x", count: 33)] {
            XCTAssertThrowsError(
                try root(["BENCH_SUITE": bad]).get(),
                "\(bad) cannot isolate, and must not fall back to the shared ~/.bench")
        }
        XCTAssertThrowsError(
            try root(["BENCH_DIR": "/r", "BENCH_SUITE": "a/b"]).get(),
            "bench refuses the suite before BENCH_DIR can win")
    }

    /// #378: an isolated helm resolved the operator's ~/.bench, so its browser pane drove his
    /// signed-in Chrome.
    func testAnIsolatedHelmGetsItsOwnBench() {
        XCTAssertEqual(
            try root(["HELM_DEFAULTS_SUITE": "iso"]).get().path, "/Users/op/.bench-iso",
            "the root `bench` uses under BENCH_SUITE=iso")
    }

    func testAHelmSuiteBenchdCannotNameIsRefusedRatherThanShared() {
        for name in ["Helm-Bench", "a.b", "-x", String(repeating: "x", count: 33)] {
            guard case .failure(let error) = root(["HELM_DEFAULTS_SUITE": name]) else {
                XCTFail("\(name) is a helm suite, but not one benchd can isolate")
                continue
            }
            XCTAssertEqual(error.variable, "HELM_DEFAULTS_SUITE")
            XCTAssertEqual(error.value, name)
        }
        let environment = ["HELM_DEFAULTS_SUITE": "helm"]
        guard case .failure(let error) = root(environment),
            case .refused(let why) = DefaultsSuite.override(in: environment)
        else {
            return XCTFail("a suite helm itself refuses never falls back to ~/.bench either")
        }
        XCTAssertEqual(error.sentence, why, "the pane says helm's own reason, not a character rule")
    }

    func testTheBenchVariablesOutrankTheHelmSuite() {
        XCTAssertEqual(
            try root(["HELM_DEFAULTS_SUITE": "iso", "BENCH_SUITE": "dev"]).get().path,
            "/Users/op/.bench-dev")
        XCTAssertEqual(
            try root(["HELM_DEFAULTS_SUITE": "Not-A-Bench", "BENCH_DIR": "/r"]).get().path, "/r",
            "an explicit root needs no suite to be valid")
    }

    func testTheOperatorsHelmStaysOnTheSharedBench() {
        for value in ["", "com.wirasm.helm"] {
            XCTAssertEqual(
                try root(["HELM_DEFAULTS_SUITE": value]).get().path, "/Users/op/.bench")
        }
    }
}
