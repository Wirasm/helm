import XCTest

@testable import Helm

/// The Archon drawer's keys (#382): each key does its one thing for the kind of run it is
/// pressed on, and nothing on a run it does not apply to.
final class ArchonKeysTests: XCTestCase {
    private let gate = ArchonRun.paused(
        id: "g",
        gate: .fixture(decisions: [.init(id: "ship", label: "Ship"), .init(id: "hold", label: nil)])
    )
    private let running = ArchonRun.fixture(id: "r", status: "running")
    private let failed = ArchonRun.fixture(id: "f", status: "failed")
    private let done = ArchonRun.fixture(id: "d", status: "completed")

    private func action(
        _ key: Character, _ run: ArchonRun?, armed: String? = nil
    ) -> ArchonKeyAction {
        ArchonKeys.action(for: key, on: run, armedCancel: armed)
    }

    func testAGateIsAnsweredWithItsKeys() {
        XCTAssertEqual(action("a", gate), .decide(.approve, gate))
        XCTAssertEqual(action("x", gate), .decide(.reject, gate))
        XCTAssertEqual(action("1", gate), .decide(.declared("ship"), gate))
        XCTAssertEqual(action("2", gate), .decide(.declared("hold"), gate))
        XCTAssertEqual(action("3", gate), .none, "only the decisions the gate declared")
        XCTAssertEqual(action("r", gate), .resume(gate))
    }

    /// The control: gate keys on runs that are not waiting do nothing, so a stray `a` can never
    /// approve something the operator was not looking at.
    func testGateKeysDoNothingOnARunThatIsNotWaiting() {
        for run in [running, failed, done] {
            XCTAssertEqual(action("a", run), .none)
            XCTAssertEqual(action("x", run), .none)
            XCTAssertEqual(action("1", run), .none)
        }
        let answered = ArchonRun.paused(id: "p", gate: .fixture(resolved: "approved"))
        XCTAssertEqual(action("a", answered), .none, "an answered gate is not asked again")
    }

    /// Cancel takes two presses on the same run; the first only arms it.
    func testCancelTakesASecondPressOnTheSameRun() {
        XCTAssertEqual(action("c", running), .armCancel(runID: "r"))
        XCTAssertEqual(action("c", running, armed: "r"), .cancel(running))
        XCTAssertEqual(action("c", running, armed: "other"), .armCancel(runID: "r"))
        XCTAssertEqual(action("c", done), .none, "a finished run has nothing to cancel")
        XCTAssertEqual(action("c", gate), .none)
    }

    func testResumeIsForFailedAndPausedRunsOnly() {
        XCTAssertEqual(action("r", failed), .resume(failed))
        XCTAssertEqual(action("r", running), .none)
        XCTAssertEqual(action("r", done), .none)
    }

    func testReturnOpensAFinishedRunAndExpandsALiveOne() {
        XCTAssertEqual(action("\r", done), .open(done))
        XCTAssertEqual(action("\r", running), .toggleExpanded(runID: "r"))
        XCTAssertEqual(action("\u{7F}", done), .dismiss(done))
        XCTAssertEqual(action("\u{7F}", running), .none, "only a finished run is cleared")
    }

    func testTheLogAndTheComposerAreAlwaysThere() {
        XCTAssertEqual(action("l", running), .followLog(running))
        XCTAssertEqual(action("/", nil), .focusComposer)
        XCTAssertEqual(action("a", nil), .none)
    }

    /// The log is followed from the run's own directory, quoted, because Archon resolves the
    /// project from where it is run.
    func testTheLogLineRunsFromTheRunsDirectory() {
        let run = ArchonRun.fixture(id: "abc", workingPath: "/tmp/it's here")
        XCTAssertEqual(
            ArchonKeys.followLogLine(for: run),
            "cd '/tmp/it'\\''s here' && archon workflow logs abc --follow")
    }
}
