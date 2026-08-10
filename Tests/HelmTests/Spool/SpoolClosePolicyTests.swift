import HelmWire
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
        AcceptedCloseRequest(
            id: RequestID(validating: "c")!, terminal: TerminalID(terminal), force: force)
    }

    /// The pty layout every helm pane really has, measured live: `login` is the session
    /// leader, and it forks the login shell as its only child.
    private static let login: pid_t = 4000
    private static let shell: pid_t = 4001
    private static let agent: pid_t = 4002

    /// A terminal pane at an idle prompt: the shell is in the foreground, and its parent is
    /// `login`. The `holdsTerminal: false` case it used to take is `canvas()` below — a canvas
    /// with a login shell's pids attached was never a state that existed.
    ///
    /// **`keyboard:` where this used to say `holdsKeyboard:` (#284)**, and nothing a close asks
    /// changed with it: `SpoolPaneState.holdsKeyboard` is now derived from the three-valued
    /// answer, so every rule below reads exactly what it read before. The third value —
    /// `.inItsSlot` — exists for the select policy and is invisible to this one, which is what
    /// `testAPaneSharingTheOperatorsSlotIsStillCloseable` pins.
    ///
    /// **`name:` is `.chosen` in every fixture below for the same reason the pids are real
    /// (#313)**: a close must not consult what the pane is called, and a fixture that left it
    /// `.unnamed` could not tell "ignored" from "absent". `SpoolNamePolicy` is the only rule that
    /// reads it.
    private func idle(keyboard: SpoolPaneState.Keyboard = .elsewhere) -> SpoolPaneState {
        SpoolPaneState(
            holdsTerminal: true, keyboard: keyboard, name: .chosen("the plan"),
            foreground: Self.shell, foregroundParent: Self.login, sessionLeader: Self.login)
    }

    /// A pane with an agent in it: the foreground is a child of the *shell*, one level deeper
    /// than an idle prompt, in the same session.
    private func busy(keyboard: SpoolPaneState.Keyboard = .elsewhere) -> SpoolPaneState {
        SpoolPaneState(
            holdsTerminal: true, keyboard: keyboard, name: .chosen("the plan"),
            foreground: Self.agent, foregroundParent: Self.shell, sessionLeader: Self.login)
    }

    /// A canvas pane, exactly as `WorkbenchSpoolPanes` reports one: no terminal, and therefore
    /// no pty and none of the three pids that describe one.
    private func canvas(keyboard: SpoolPaneState.Keyboard = .elsewhere) -> SpoolPaneState {
        SpoolPaneState(
            holdsTerminal: false, keyboard: keyboard, name: .chosen("the plan"),
            foreground: nil, foregroundParent: nil, sessionLeader: nil)
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

    func testAPaneSharingTheOperatorsSlotIsStillCloseable() {
        // **The control for #284's widening of `SpoolPaneState`, and it must pass either way.**
        // `.inItsSlot` is a state this policy could not previously describe, and the risk of
        // adding it is that a close starts refusing more than #176 said it should: a background
        // tab of the operator's slot is not the pane they are working in, closing it removes
        // nothing they can see, and the surviving tabs simply reflow. `SpoolSelectPolicy` refuses
        // exactly this pane, which is what makes the two rules different rather than one copied.
        XCTAssertNil(SpoolClosePolicy.refusal(for: request(), pane: idle(keyboard: .inItsSlot)))
        XCTAssertNil(SpoolClosePolicy.refusal(for: request(), pane: canvas(keyboard: .inItsSlot)))
    }

    // MARK: - A canvas pane (#284)

    func testACanvasPaneNobodyIsInClosesWithNothingExplicit() {
        // The whole of this half of #284, and the reason `push.sh` stopped being add-only: an
        // agent that pushed an artifact can take it off the bench again, with no `force` and no
        // ceremony. Replaces `testACanvasPaneIsNotClosedOnARequestMeantForATerminal`, whose
        // subject — the "holds a canvas, not a terminal" refusal — no longer exists.
        XCTAssertNil(SpoolClosePolicy.refusal(for: request(), pane: canvas()))
    }

    func testACanvasIsNeverBusySoItNeverNeedsForce() {
        // Rule 2 has nothing to test on a canvas: no pty, no process group, nothing unwritten.
        // Asserted on the type rather than only through the policy, because `isBusy` is where
        // the rule is now stated — `holdsTerminal` short-circuits it before any pid is read.
        XCTAssertFalse(canvas().isBusy)
        XCTAssertNil(SpoolClosePolicy.refusal(for: request(), pane: canvas()))
    }

    func testACanvasThatSomehowReportsAForegroundIsStillNotBusy() {
        // The guard is `holdsTerminal`, not "it happens to have no pid". `WorkbenchSpoolPanes`
        // reads `foreground` out of the terminal sessions, so a canvas arrives with nil today —
        // this pins that the rule does not depend on that lookup staying that way.
        let odd = SpoolPaneState(
            holdsTerminal: false, keyboard: .elsewhere, name: .chosen("the plan"),
            foreground: Self.agent,
            foregroundParent: nil, sessionLeader: nil)
        XCTAssertFalse(odd.isBusy)
        XCTAssertNil(SpoolClosePolicy.refusal(for: request(), pane: odd))
    }

    func testTheOperatorsOwnCanvasIsRefusedAndForceDoesNotOverrideIt() {
        // Rule 1 applies to a canvas unchanged and for its own reason: the operator can be
        // reading a plan as easily as typing in a terminal, and *never remove what someone is
        // looking at* says nothing about what the pane holds. This is the control that would
        // fail if #284 had been implemented by exempting canvases from the policy rather than by
        // removing one refusal from it.
        let refusal = SpoolClosePolicy.refusal(
            for: request(force: true), pane: canvas(keyboard: .here))
        XCTAssertEqual(refusal?.reason.contains("operator") == true, true)
        XCTAssertEqual(refusal?.reason.contains("force") == true, true)
    }

    // MARK: - What is refused

    func testAPaneHelmDoesNotHaveIsRefusedByName() {
        // Never silently nothing: "helm closed no pane" and "helm is not running" must not
        // look the same, which is the silence this whole ladder exists to remove.
        let refusal = SpoolClosePolicy.refusal(for: request(), pane: nil)
        XCTAssertEqual(refusal?.reason.contains(terminal.uuidString), true)
    }

    func testThePaneTheOperatorIsWorkingInIsNeverClosed() {
        // #125's rule is *appear, don't seize*; this is its destructive counterpart, and helm
        // knows which slot has focus.
        let refusal = SpoolClosePolicy.refusal(for: request(), pane: idle(keyboard: .here))
        XCTAssertEqual(refusal?.reason.contains("operator") == true, true)
    }

    func testForceDoesNotOverrideTheOperator() {
        // The load-bearing asymmetry. `force` is a caller asserting about work IT owns; where
        // the operator's eyes are is not something a file on disk gets a say in. It is also
        // why the focus rule is checked before the busy one — a forced request against the
        // operator's own pane must refuse on focus, not sail past it.
        let refusal = SpoolClosePolicy.refusal(
            for: request(force: true), pane: busy(keyboard: .here))
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
            holdsTerminal: true, keyboard: .elsewhere, name: .chosen("the plan"),
            foreground: Self.shell,
            foregroundParent: 1, sessionLeader: Self.shell)
        XCTAssertTrue(leaderIsForeground.isBusy)
    }

    func testASurfaceWithNoProcessAtAllIsNotBusy() {
        // A pane whose shell never started or has already exited holds no work to destroy.
        XCTAssertFalse(
            SpoolPaneState(
                holdsTerminal: true, keyboard: .elsewhere, name: .chosen("the plan"),
                foreground: nil,
                foregroundParent: nil, sessionLeader: nil
            ).isBusy)
    }

    func testAForegroundHelmCannotAskAboutCountsAsBusy() {
        // A syscall that cannot answer means helm does not know whether it would be destroying
        // work. Unknown is not idle — and the caller that wants it gone anyway can say `force`.
        let unknown = SpoolPaneState(
            holdsTerminal: true, keyboard: .elsewhere, name: .chosen("the plan"),
            foreground: Self.agent,
            foregroundParent: nil, sessionLeader: nil)
        XCTAssertTrue(unknown.isBusy)
        XCTAssertNotNil(SpoolClosePolicy.refusal(for: request(), pane: unknown))
        XCTAssertNil(SpoolClosePolicy.refusal(for: request(force: true), pane: unknown))
    }
}
