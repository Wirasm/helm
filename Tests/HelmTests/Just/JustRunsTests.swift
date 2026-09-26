import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The just layer from helm's side (#356): a key asks benchd to run a recipe as the operator,
/// and a run of his that fails is kept for the status bar.
@MainActor
final class JustRunsTests: XCTestCase {
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var recipes: [String] = []
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recipes
        }
        func add(_ recipe: String) {
            lock.lock()
            recipes.append(recipe)
            lock.unlock()
        }
    }

    private func frame(_ run: String, exit: Int?) -> Data {
        let exitJSON = exit.map(String.init) ?? "null"
        return Data(
            #"{"event":{"seq":9,"at":"t","kind":"just/finished","data":{"run":"\#(run)","recipe":"day","exit":\#(exitJSON),"log":"/r/just/\#(run).log"}}}"#
                .utf8)
    }

    func testAFailedRunOfHisIsKeptAndASuccessfulOneIsNot() {
        let asked = Asked()
        let runs = JustRuns { recipe in
            asked.add(recipe)
            return BenchJustStarted(run: "run-\(asked.all.count)", log: "/r/just/x.log")
        }
        runs.run("day")
        runs.run("day")
        XCTAssertTrue(Eventually.holds { asked.all.count == 2 })

        // Whether each ending arrives before or after its answer, it is matched to the run.
        runs.receive(frame("run-1", exit: 0))
        runs.receive(frame("run-2", exit: 2))

        XCTAssertTrue(Eventually.holds { runs.failures.map(\.run) == ["run-2"] })
        XCTAssertEqual(runs.failures.first?.exit, 2)
        runs.dismiss("run-2")
        XCTAssertEqual(runs.failures, [])
    }

    /// A short recipe can end before helm has read the answer that names it.
    func testAnEndingHeardBeforeTheAnswerIsStillHis() {
        let gate = DispatchSemaphore(value: 0)
        let runs = JustRuns { _ in
            gate.wait()
            return BenchJustStarted(run: "run-7", log: "/r/just/run-7.log")
        }
        runs.run("day")
        runs.receive(frame("run-7", exit: 1))
        gate.signal()
        XCTAssertTrue(Eventually.holds { runs.failures.map(\.run) == ["run-7"] })
    }

    /// An agent's run is the agent's to report: an ending for a run helm did not start is not
    /// shown, and a document frame or another event kind is not an ending at all.
    func testOnlyHisOwnRunsAreShown() {
        let runs = JustRuns { _ in throw JustRuns.Refused(description: "unused") }
        runs.receive(frame("run-99", exit: 1))
        runs.receive(Data(#"{"event":{"seq":1,"at":"t","kind":"rules/loaded","data":{}}}"#.utf8))
        XCTAssertEqual(runs.failures, [])
    }

    func testARunThatCannotStartSaysWhy() {
        let runs = JustRuns { _ in
            throw JustRuns.Refused(description: "no justfile at /r/rules/justfile")
        }
        runs.run("day")
        XCTAssertTrue(
            Eventually.holds {
                runs.refusal == "just day: no justfile at /r/rules/justfile"
            })
    }
}
