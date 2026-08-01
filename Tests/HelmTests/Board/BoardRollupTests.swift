import XCTest

@testable import Helm

/// The per-workspace rollup: one workspace's mark from the whole registry and the
/// pids that workspace's own terminals are running.
///
/// Pure, so every acceptance rule on #36 is checkable without a window, a pty or a
/// live agent — which matters, because the pid match itself cannot be exercised
/// under a shielded display.
final class BoardRollupTests: XCTestCase {

    private func row(_ pid: pid_t, _ status: AgentStatus?, cwd: String = "/ws") -> AgentSession {
        AgentSession(pid: pid, cwd: cwd, status: status)
    }

    // MARK: - The mark

    func testLitWhenAnyHostedAgentIsNotWorking() {
        let registry = [row(1, .busy), row(2, .idle)]

        XCTAssertEqual(
            BoardModel.presence(of: registry, hosted: [1, 2]), .notWorking,
            "the mixed case is ordinary, not an edge — one stopped agent is the whole signal")
    }

    func testWaitingLightsTheSameAsIdle() {
        XCTAssertEqual(BoardModel.presence(of: [row(1, .waiting)], hosted: [1]), .notWorking)
    }

    func testWorkingWhenEveryHostedAgentIsWorking() {
        let registry = [row(1, .busy), row(2, .shell)]

        XCTAssertEqual(BoardModel.presence(of: registry, hosted: [1, 2]), .working)
    }

    // MARK: - Absence

    func testNoPresenceWhenWorkspaceHostsNoAgent() {
        let registry = [row(1, .idle), row(2, .busy)]

        XCTAssertNil(
            BoardModel.presence(of: registry, hosted: [77, 78]),
            "plain shells and pi read as unmarked, never as idle")
    }

    func testNoPresenceWhenWorkspaceHostsNothingAtAll() {
        XCTAssertNil(BoardModel.presence(of: [row(1, .idle)], hosted: []))
    }

    func testNoPresenceWhenRegistryIsEmpty() {
        XCTAssertNil(BoardModel.presence(of: [], hosted: [1, 2]))
    }

    // MARK: - The pid filter is load-bearing

    func testUnhostedRowsAreIgnoredEvenSharingACwdAndEvenBusy() {
        // The registry as it actually stood when the mechanism was verified: six
        // rows, exactly one helm-hosted. Of the five that were not, one shared the
        // same cwd and one was busy. A cwd match would have lit this workspace for
        // another editor's agent.
        let registry = [
            row(9139, .idle, cwd: "/ws/helm"),  // ours
            row(56062, .busy, cwd: "/ws/helm"),  // another editor, same cwd, busy
            row(72261, .idle, cwd: "/ws/helm"),
            row(43564, .idle, cwd: "/ws/helm"),
            row(87311, .idle, cwd: "/ws/archon"),
            row(43971, .idle, cwd: "/ws/course"),
        ]

        XCTAssertEqual(
            BoardModel.presence(of: registry, hosted: [9139]), .notWorking,
            "our one row decides the mark; the other five are not ours to report")
    }

    func testDeadPidRowCannotProduceAMark() {
        // A stale file left by an agent that exited. Its pid matches no live
        // surface, so it contributes nothing — which is the only reason the board
        // needs no freshness check, and fortunate, since statusUpdatedAt is a
        // last-transition time rather than a heartbeat.
        XCTAssertNil(BoardModel.presence(of: [row(4242, .idle)], hosted: [9139]))
    }

    // MARK: - No status, no chrome

    func testRowWithoutStatusContributesNothing() {
        XCTAssertNil(
            BoardModel.presence(of: [row(9139, nil)], hosted: [9139]),
            "a session mid-transition renders nothing rather than defaulting to idle")
    }

    func testRowWithoutStatusDoesNotSuppressASiblingsMark() {
        let registry = [row(1, nil), row(2, .idle)]

        XCTAssertEqual(BoardModel.presence(of: registry, hosted: [1, 2]), .notWorking)
    }

    func testRowWithoutStatusDoesNotInventANotWorkingMark() {
        let registry = [row(1, nil), row(2, .busy)]

        XCTAssertEqual(
            BoardModel.presence(of: registry, hosted: [1, 2]), .working,
            "the unknown row abstains — it does not vote either way")
    }
}
