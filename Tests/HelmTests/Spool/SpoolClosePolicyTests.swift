import XCTest

@testable import Helm

/// What may be torn down, and what may not — the half of #176 that is the whole of #176.
///
/// Every rule here is about the live bench, and every one of them is exercised with no bench,
/// no ghostty surface and no pty. That is what `SpoolPaneState` buys: the adapter reports
/// facts, the policy decides, and the deciding is the part worth testing.
final class SpoolClosePolicyTests: XCTestCase {
    private let terminal = UUID()

    private func request(force: Bool = false) -> AcceptedCloseRequest {
        AcceptedCloseRequest(id: "c", terminal: terminal, force: force)
    }

    /// The pty layout every helm pane really has, measured live: `login` is the session
    /// leader, and it forks the login shell as its only child.
    private static let login: pid_t = 4000
    private static let shell: pid_t = 4001
    private static let agent: pid_t = 4002

    /// A pane at an idle prompt: the shell is in the foreground, and its parent is `login`.
    private func idle(
        holdsTerminal: Bool = true, holdsKeyboard: Bool = false
    ) -> SpoolPaneState {
        SpoolPaneState(
            holdsTerminal: holdsTerminal, holdsKeyboard: holdsKeyboard,
            foreground: Self.shell, foregroundParent: Self.login, sessionLeader: Self.login)
    }

    /// A pane with an agent in it: the foreground is a child of the *shell*, one level deeper
    /// than an idle prompt, in the same session.
    private func busy(holdsKeyboard: Bool = false) -> SpoolPaneState {
        SpoolPaneState(
            holdsTerminal: true, holdsKeyboard: holdsKeyboard,
            foreground: Self.agent, foregroundParent: Self.shell, sessionLeader: Self.login)
    }

    // MARK: - What is closed

    func testAnIdleTerminalNobodyIsInMayBeClosedWithNothingExplicit() {
        // The case the capability exists for: an agent finished, its pane is sitting at a
        // prompt, and tidying it up must not need a ceremony.
        XCTAssertNil(SpoolClosePolicy.refusal(for: request(), pane: idle()))
    }

    func testALivePaneClosesWhenTheCallerSaysItMeansIt() {
        // The explicit thing #176 asks for. Refusing outright would withhold the capability in
        // its main case — a spawned agent that has just finished IS the live process in its
        // own pane.
        XCTAssertNil(SpoolClosePolicy.refusal(for: request(force: true), pane: busy()))
    }

    // MARK: - What is refused

    func testAPaneHelmDoesNotHaveIsRefusedByName() {
        // Never silently nothing: "helm closed no pane" and "helm is not running" must not
        // look the same, which is the silence this whole ladder exists to remove.
        let refusal = SpoolClosePolicy.refusal(for: request(), pane: nil)
        XCTAssertEqual(refusal?.reason.contains(terminal.uuidString), true)
    }

    func testACanvasPaneIsNotClosedOnARequestMeantForATerminal() {
        let refusal = SpoolClosePolicy.refusal(
            for: request(force: true), pane: idle(holdsTerminal: false))
        XCTAssertEqual(refusal?.reason.contains("canvas") == true, true)
    }

    func testThePaneTheOperatorIsWorkingInIsNeverClosed() {
        // #125's rule is *appear, don't seize*; this is its destructive counterpart, and helm
        // knows which slot has focus.
        let refusal = SpoolClosePolicy.refusal(for: request(), pane: idle(holdsKeyboard: true))
        XCTAssertEqual(refusal?.reason.contains("operator") == true, true)
    }

    func testForceDoesNotOverrideTheOperator() {
        // The load-bearing asymmetry. `force` is a caller asserting about work IT owns; where
        // the operator's eyes are is not something a file on disk gets a say in. It is also
        // why the focus rule is checked before the busy one — a forced request against the
        // operator's own pane must refuse on focus, not sail past it.
        let refusal = SpoolClosePolicy.refusal(
            for: request(force: true), pane: busy(holdsKeyboard: true))
        XCTAssertEqual(refusal?.reason.contains("operator") == true, true)
        XCTAssertEqual(refusal?.reason.contains("force") == true, true)
    }

    func testALivePaneRefusesWithoutForceAndNamesWhatWouldDie() {
        let refusal = SpoolClosePolicy.refusal(for: request(), pane: busy())
        XCTAssertEqual(refusal?.reason.contains("pid 4002") == true, true)
        XCTAssertEqual(refusal?.reason.contains("force") == true, true)
    }

    // MARK: - Is anything running in there

    func testTheForegroundBeingAChildOfTheSessionLeaderIsAnIdlePrompt() {
        // The whole test, and it is two syscalls: `login` is the session leader and forks the
        // shell, so the shell's parent IS the leader and a job's parent is the shell.
        XCTAssertFalse(idle().isBusy)
        XCTAssertTrue(busy().isBusy)
    }

    func testTheForegroundBeingItsOwnSessionLeaderIsNotReadAsIdle() {
        // The rule this replaced, pinned so it cannot come back. `getsid(fg) == fg` looks like
        // the same test and is not — the pty's session leader is `login`, never the shell — so
        // it called every idle pane busy. Under this rule that shape is still not *idle*: it is
        // a layout helm does not recognise, and an unrecognised layout refuses rather than
        // destroys.
        let leaderIsForeground = SpoolPaneState(
            holdsTerminal: true, holdsKeyboard: false, foreground: Self.shell,
            foregroundParent: 1, sessionLeader: Self.shell)
        XCTAssertTrue(leaderIsForeground.isBusy)
    }

    func testASurfaceWithNoProcessAtAllIsNotBusy() {
        // A pane whose shell never started or has already exited holds no work to destroy.
        XCTAssertFalse(
            SpoolPaneState(
                holdsTerminal: true, holdsKeyboard: false, foreground: nil,
                foregroundParent: nil, sessionLeader: nil
            ).isBusy)
    }

    func testAForegroundHelmCannotAskAboutCountsAsBusy() {
        // A syscall that cannot answer means helm does not know whether it would be destroying
        // work. Unknown is not idle — and the caller that wants it gone anyway can say `force`.
        let unknown = SpoolPaneState(
            holdsTerminal: true, holdsKeyboard: false, foreground: Self.agent,
            foregroundParent: nil, sessionLeader: nil)
        XCTAssertTrue(unknown.isBusy)
        XCTAssertNotNil(SpoolClosePolicy.refusal(for: request(), pane: unknown))
        XCTAssertNil(SpoolClosePolicy.refusal(for: request(force: true), pane: unknown))
    }
}
