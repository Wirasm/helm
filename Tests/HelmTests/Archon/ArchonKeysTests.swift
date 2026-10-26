import XCTest

@testable import Helm

/// The Archon drawer's keys (#382): each key does its one thing for the kind of row it is
/// pressed on, and nothing on a row it does not apply to.
final class ArchonKeysTests: XCTestCase {
    private let running = ArchonRun.fixture(id: "r", status: "running")
    private let paused = ArchonRun.fixture(id: "p", status: "paused")
    private let failed = ArchonRun.fixture(id: "f", status: "failed")
    private let done = ArchonRun.fixture(id: "d", status: "completed")

    private func action(
        _ key: Character, _ run: ArchonRun?, armed: String? = nil
    ) -> ArchonKeyAction {
        ArchonKeys.action(for: key, on: run.map(ArchonDrawerRow.run), armedCancel: armed)
    }

    private func action(_ key: Character, _ item: ArchonAttentionItem) -> ArchonKeyAction {
        ArchonKeys.action(for: key, on: .item(item), armedCancel: nil)
    }

    /// An item's answers are its number keys, in the order Archon declared them.
    func testAnItemIsAnsweredWithItsNumberKeys() throws {
        let select = try ArchonAttentionItem.select()
        XCTAssertEqual(
            action("1", select), .choose(ArchonChoice(id: "rerun", label: "Review again"), select))
        XCTAssertEqual(
            action("2", select), .choose(ArchonChoice(id: "finish", label: "finish"), select))
        XCTAssertEqual(action("3", select), .none, "only the options Archon declared")
        XCTAssertEqual(action("a", select), .none, "a select offers no `approve`")
        XCTAssertEqual(action("\r", select), .toggleExpanded(rowID: "attention:run-1"))
        XCTAssertEqual(action("r", select), .none, "a question is answered, not resumed")
    }

    /// `a` and `x` keep meaning approve and reject wherever an item offers those ids.
    func testApproveAndRejectKeepTheirLetters() throws {
        let items = try ArchonAttentionItem.captured()
        let approval = items[2]
        let gate = items[4]
        for item in [approval, gate] {
            XCTAssertEqual(action("a", item), .choose(item.choices[0], item))
            XCTAssertEqual(action("x", item), .choose(item.choices[1], item))
        }
        let message = items[1]
        XCTAssertEqual(action("1", message), .choose(message.choices[0], message))
        XCTAssertEqual(action("1", items[3]), .none, "a multi-select is answered in a terminal")
    }

    /// The control: answer keys on runs do nothing, so a stray `1` can never answer something
    /// the operator was not looking at.
    func testAnswerKeysDoNothingOnARun() {
        for run in [running, paused, failed, done] {
            XCTAssertEqual(action("a", run), .none)
            XCTAssertEqual(action("x", run), .none)
            XCTAssertEqual(action("1", run), .none)
        }
    }

    /// Cancel takes two presses on the same run; the first only arms it.
    func testCancelTakesASecondPressOnTheSameRun() {
        XCTAssertEqual(action("c", running), .armCancel(runID: "r"))
        XCTAssertEqual(action("c", running, armed: "r"), .cancel(running))
        XCTAssertEqual(action("c", running, armed: "other"), .armCancel(runID: "r"))
        XCTAssertEqual(action("c", done), .none, "a finished run has nothing to cancel")
        XCTAssertEqual(action("c", paused), .none)
    }

    /// A paused run in the run list is one the queue does not hold, such as an answer recorded
    /// where nothing continued it: `r` is how it moves again.
    func testResumeIsForFailedAndPausedRunsOnly() {
        XCTAssertEqual(action("r", failed), .resume(runID: "f"))
        XCTAssertEqual(action("r", paused), .resume(runID: "p"))
        XCTAssertEqual(action("r", running), .none)
        XCTAssertEqual(action("r", done), .none)
    }

    func testReturnOpensAFinishedRunAndExpandsALiveOne() {
        XCTAssertEqual(action("\r", done), .open(done))
        XCTAssertEqual(action("\r", running), .toggleExpanded(rowID: "r"))
        XCTAssertEqual(action("\u{7F}", done), .dismiss(done))
        XCTAssertEqual(action("\u{7F}", running), .none, "only a finished run is cleared")
    }

    func testTheLogAndTheComposerAreAlwaysThere() throws {
        let select = try ArchonAttentionItem.select()
        XCTAssertEqual(
            action("l", running), .followLog(runID: "r", workingPath: "/tmp/project"))
        XCTAssertEqual(
            action("l", select), .followLog(runID: "run-1", workingPath: "/tmp/project"))
        XCTAssertEqual(action("/", nil), .focusComposer)
        XCTAssertEqual(action("w", nil), .pickWorkflow)
        XCTAssertEqual(action("w", select), .pickWorkflow, "whatever row is picked")
        XCTAssertEqual(action("a", nil), .none)
    }

    /// The log is followed from the run's own directory, quoted, because Archon resolves the
    /// project from where it is run.
    func testTheLogLineRunsFromTheRunsDirectory() {
        XCTAssertEqual(
            ArchonKeys.followLogLine(runID: "abc", workingPath: "/tmp/it's here"),
            "cd '/tmp/it'\\''s here' && archon workflow logs abc --follow")
    }
}
