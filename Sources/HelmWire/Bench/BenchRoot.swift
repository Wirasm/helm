import Foundation

/// Where a bench keeps its state: `bench_wire::resolve_root` plus the suite rule of
/// `SuiteName::validate` (`daemon/crates/bench-wire/src/lib.rs`), spelled again because Swift
/// cannot call Rust. `daemon/fixtures/bench-root.json` is the table both copies are
/// checked against (`BenchWireConformanceTests` here, `bench-wire`'s own tests there).
///
/// In order:
///
/// 1. `BENCH_DIR` names the root outright. Empty is unset, in `bench` too (#395).
/// 2. `BENCH_SUITE` → `~/.bench-<suite>`.
/// 3. `HELM_DEFAULTS_SUITE` → `~/.bench-<suite>`. An isolated helm gets its own bench, which
///    is what `bench` run with `BENCH_SUITE=<suite>` uses (#378).
/// 4. Otherwise the shared `~/.bench`.
///
/// **A suite that cannot isolate is refused, never defaulted to `~/.bench`.** The shared root is
/// the operator's: its browser is his signed-in Chrome, and a pane on it forwards clicks and keys
/// into it. Before #378 an isolated helm resolved it anyway, because only rules 1, 2 and 4
/// existed. A helm suite name benchd's `SuiteName` would refuse, such as `Helm-Bench`, is
/// refused here too, rather than mapped to some other name that helm and `bench` would then
/// disagree about.
///
/// Lives in HelmWire, and reads the helm suite through the same `DefaultsSuite.override` as
/// `DefaultsDomain`, so "is this helm isolated?" has one answer.
package enum BenchRoot {
    package static let directoryVariable = "BENCH_DIR"
    package static let suiteVariable = "BENCH_SUITE"

    package static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> Result<URL, BenchRootError> {
        // The bench suite is judged first, as `bench` judges it before resolving anything: a
        // name that cannot isolate is an error even when BENCH_DIR would win.
        let benchSuite = environment[suiteVariable]
        if let benchSuite, !isSuiteName(benchSuite) {
            return .failure(BenchRootError(variable: suiteVariable, value: benchSuite))
        }
        if let dir = environment[directoryVariable], !dir.isEmpty {
            return .success(URL(fileURLWithPath: dir, isDirectory: true))
        }
        if let benchSuite {
            return .success(root(suite: benchSuite, home: home))
        }
        switch DefaultsSuite.override(in: environment) {
        case .none:
            return .success(home.appendingPathComponent(".bench", isDirectory: true))
        case .suite(let name):
            guard isSuiteName(name) else {
                return .failure(BenchRootError(variable: DefaultsSuite.suiteVariable, value: name))
            }
            return .success(root(suite: name, home: home))
        case .refused(let why):
            // A running helm never gets here, because `DefaultsDomain.resolve` stops the launch
            // first. If something does, the shared root is the one answer that is never right.
            let raw = environment[DefaultsSuite.suiteVariable] ?? ""
            return .failure(
                BenchRootError(variable: DefaultsSuite.suiteVariable, value: raw, sentence: why))
        }
    }

    /// Where this helm reaches benchd: the root's `benchd.sock`, or `BENCH_URL`. The root is
    /// judged first, as `bench` judges it, so a suite that cannot isolate is refused even with a
    /// URL set. The one place the socket is derived: every caller asks here.
    package static func endpoint(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> Result<BenchEndpoint, BenchRootError> {
        resolve(environment: environment, home: home).flatMap { root in
            let url = environment[BenchEndpoint.urlVariable]
            let socket = root.appendingPathComponent("benchd.sock").path
            guard let endpoint = BenchEndpoint.parse(url: url, socket: socket) else {
                return .failure(
                    BenchRootError(
                        variable: BenchEndpoint.urlVariable, value: url ?? "",
                        sentence: "\(BenchEndpoint.urlVariable)=\(url ?? "") is not "
                            + "tcp://<host>:<port>, so helm will not guess which benchd you meant"))
            }
            return .success(endpoint)
        }
    }

    private static func root(suite: String, home: URL) -> URL {
        home.appendingPathComponent(".bench-\(suite)", isDirectory: true)
    }

    /// `SuiteName::validate`: lowercase ASCII letters, digits and `-`, starting alphanumeric,
    /// at most 32 bytes.
    private static func isSuiteName(_ raw: String) -> Bool {
        guard let first = raw.first, raw.utf8.count <= 32, first != "-" else { return false }
        return raw.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }
}

package struct BenchRootError: Error, Equatable {
    /// The variable that was refused: `BENCH_SUITE` or `HELM_DEFAULTS_SUITE` naming a suite, or
    /// `BENCH_URL`.
    package let variable: String
    package let value: String
    /// Why, for the pane to show.
    package let sentence: String

    /// A name `SuiteName` would refuse. The other refusal, a helm suite `DefaultsSuite` itself
    /// refuses, passes its own reason.
    init(variable: String, value: String, sentence: String? = nil) {
        self.variable = variable
        self.value = value
        self.sentence =
            sentence
            ?? "\(variable)=\(value) is not a bench suite name (lowercase letters, digits and "
            + "'-', at most 32), so helm will not guess which bench you meant"
    }
}
