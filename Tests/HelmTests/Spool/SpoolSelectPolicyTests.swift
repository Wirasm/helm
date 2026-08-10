import HelmWire
import XCTest

@testable import Helm

/// What may be brought forward, and what may not — the focus half of #284.
///
/// Every rule here is about the live bench, and every one of them is exercised with no bench, no
/// ghostty surface and no pty. That is what `SpoolPaneState` buys, and it is the same split
/// `SpoolClosePolicyTests` relies on: the adapter reports facts, the policy decides, and the
/// deciding is the part worth testing.
///
/// **The interesting tests here are the ones that would pass under a copy of
/// `SpoolClosePolicy` and should not** — `testABackgroundTabOfTheOperatorsSlotIsRefused` above
/// all. `holdsKeyboard` is false for that pane, so a select that reused the close rule would
/// allow it and hand the operator's keyboard to a pane they were not looking at.
final class SpoolSelectPolicyTests: XCTestCase {
    private let pane = UUID()

    private func request() -> AcceptedSelectRequest {
        AcceptedSelectRequest(id: "s", pane: TerminalID(pane))
    }

    /// A pane as `WorkbenchSpoolPanes` reports one. The pids are a terminal's, and they are
    /// deliberately present in every fixture: a select must not consult them, and a fixture that
    /// left them nil could not tell "ignored" from "absent".
    private func state(_ keyboard: SpoolPaneState.Keyboard) -> SpoolPaneState {
        SpoolPaneState(
            holdsTerminal: true, keyboard: keyboard, foreground: 5001, foregroundParent: 5000,
            sessionLeader: 5000)
    }

    private func canvas(_ keyboard: SpoolPaneState.Keyboard) -> SpoolPaneState {
        SpoolPaneState(
            holdsTerminal: false, keyboard: keyboard, foreground: nil, foregroundParent: nil,
            sessionLeader: nil)
    }

    // MARK: - What is shown

    func testAPaneInAnotherSlotIsShown() {
        // The case the capability exists for: an agent pushed an artifact, it landed as a
        // background tab in a slot the operator is not in, and making it visible costs them
        // nothing.
        XCTAssertNil(SpoolSelectPolicy.refusal(for: request(), pane: state(.elsewhere)))
        XCTAssertNil(SpoolSelectPolicy.refusal(for: request(), pane: canvas(.elsewhere)))
    }

    func testALivePaneIsShownWithoutAnythingExplicit() {
        // A select destroys nothing, so `CloseRequest.force`'s question does not arise — and the
        // pids above are what make this an assertion rather than a coincidence: a policy that
        // had copied `SpoolClosePolicy.isBusy` across would refuse a pane with an agent running
        // in it, which is precisely the pane an agent most often wants to put on screen.
        let busy = SpoolPaneState(
            holdsTerminal: true, keyboard: .elsewhere, foreground: 5002, foregroundParent: 5001,
            sessionLeader: 5000)
        XCTAssertTrue(busy.isBusy, "the fixture must really look busy for this to prove anything")
        XCTAssertNil(SpoolSelectPolicy.refusal(for: request(), pane: busy))
    }

    // MARK: - What is refused

    func testAPaneHelmDoesNotHaveIsRefusedByName() {
        // Never silently nothing: "helm showed no pane" and "helm is not running" must not look
        // the same, which is the silence this whole ladder exists to remove.
        let refusal = SpoolSelectPolicy.refusal(for: request(), pane: nil)
        XCTAssertEqual(refusal?.reason.contains(pane.uuidString), true)
    }

    func testThePaneTheOperatorIsWorkingInIsRefused() {
        // The operator's standing decision, in his own words: refuse when that pane holds the
        // operator's keyboard, on the same address rule helm-close already uses.
        let refusal = SpoolSelectPolicy.refusal(for: request(), pane: state(.here))
        XCTAssertEqual(refusal?.reason.contains("operator") == true, true)
        XCTAssertEqual(
            refusal?.reason.contains("nothing to bring forward") == true, true,
            "…and it says why the refusal costs the caller nothing: the pane is already the one "
                + "being looked at")
    }

    func testABackgroundTabOfTheOperatorsSlotIsRefused() {
        // **The test this policy exists for, and the one a copy of `SpoolClosePolicy` fails.**
        // `holdsKeyboard` is FALSE for this pane — it is not the focused pane — yet showing it
        // makes it the focused pane, because `Workbench.focusedPane` is the focused slot's
        // *selection*. A select is a displacement where a close is a removal, and that is the
        // whole difference between the two rules.
        let refusal = SpoolSelectPolicy.refusal(for: request(), pane: state(.inItsSlot))
        XCTAssertFalse(
            state(.inItsSlot).holdsKeyboard,
            "the premise: this pane does not hold the keyboard, which is why holdsKeyboard alone "
                + "cannot be the rule")
        XCTAssertEqual(refusal?.reason.contains("take their keyboard") == true, true)
        XCTAssertEqual(
            refusal?.reason.contains(pane.uuidString), true, "and it names the pane it refused")
    }

    func testACanvasInTheOperatorsSlotIsRefusedExactlyAsATerminalIs() {
        // What the pane holds says nothing about where the operator is looking — the same
        // symmetry #284's close half already settled, spelled the other way round.
        XCTAssertNotNil(SpoolSelectPolicy.refusal(for: request(), pane: canvas(.here)))
        XCTAssertNotNil(SpoolSelectPolicy.refusal(for: request(), pane: canvas(.inItsSlot)))
    }

    // MARK: - The invariant the type carries

    func testHoldsKeyboardIsExactlyTheHereCase() {
        // `SpoolClosePolicy` reads `holdsKeyboard` and nothing else, so the derivation is what
        // keeps #176's rule meaning what it meant. A pair of independent booleans would have made
        // `(holds: true, inSlot: false)` constructable; this is the assertion that the pair does
        // not exist.
        XCTAssertTrue(state(.here).holdsKeyboard)
        XCTAssertFalse(state(.inItsSlot).holdsKeyboard)
        XCTAssertFalse(state(.elsewhere).holdsKeyboard)
    }
}
