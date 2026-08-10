import HelmWire
import XCTest

@testable import Helm

/// What may be called something else, and what may not — the ownership half of #313.
///
/// Every rule here is about the live bench, and every one of them is exercised with no bench, no
/// ghostty surface and no pty. That is what `SpoolPaneState` buys, and it is the same split
/// `SpoolClosePolicyTests` and `SpoolSelectPolicyTests` rely on: the adapter reports facts, the
/// policy decides, and the deciding is the part worth testing.
///
/// **The interesting tests here are the two that make the operator's ruling checkable rather than
/// asserted** — `testAPaneWearingOnlyHelmsOwnDerivedNameIsRenamedFreely`, because helm labels every
/// spool-spawned pane and a rule that could not tell its own label from somebody's choice would
/// refuse the agent it had just spawned; and
/// `testAPaneTheOperatorIsWorkingInIsNamedLikeAnyOther`, because it is the one place this policy
/// deliberately diverges from the two that came before it.
final class SpoolNamePolicyTests: XCTestCase {
    private let pane = UUID()

    private func request(
        _ name: String = "review the diff", rename: Bool = false
    )
        -> AcceptedNameRequest
    {
        AcceptedNameRequest(id: "n", pane: TerminalID(pane), name: name, rename: rename)
    }

    /// A pane as `WorkbenchSpoolPanes` reports one. The pids and the keyboard are deliberately
    /// non-trivial in every fixture: a name must consult neither, and a fixture that left them
    /// nil or `.elsewhere` could not tell "ignored" from "absent".
    private func state(
        _ name: PaneName, keyboard: SpoolPaneState.Keyboard = .elsewhere, holdsTerminal: Bool = true
    ) -> SpoolPaneState {
        SpoolPaneState(
            holdsTerminal: holdsTerminal, keyboard: keyboard, name: name, foreground: 5002,
            foregroundParent: 5001, sessionLeader: 5000)
    }

    // MARK: - What is named

    func testAPaneNothingHasNamedIsNamed() {
        // The plain case, and the operator's own words for it: agents "by default … name new
        // panes". Nobody is calling this pane anything, so nothing is taken from anyone.
        XCTAssertNil(SpoolNamePolicy.refusal(for: request(), pane: state(.unnamed)))
    }

    func testAPaneWearingOnlyHelmsOwnDerivedNameIsRenamedFreely() {
        // **The test the provenance exists for.** Every spool-spawned pane arrives carrying
        // `PaneName.derived(for:)`, so under an undifferentiated `String?` this pane would look
        // exactly like one somebody had named — and the agent helm had just spawned would be
        // refused when it named its own pane, inverting the ruling. Nobody chose these words.
        XCTAssertNil(
            SpoolNamePolicy.refusal(for: request(), pane: state(.derived("claude · helm"))))
    }

    func testAPaneTheOperatorIsWorkingInIsNamedLikeAnyOther() {
        // **Where this policy diverges from the other two addressed verbs, deliberately.** A close
        // refuses `.here` because it destroys work; a select refuses `.here` and `.inItsSlot`
        // because showing a tab of that slot moves the keyboard. Naming moves nothing and destroys
        // nothing, so there is no version of this rule that would be about the keyboard — and a
        // policy that copied one of its neighbours would refuse the pane an agent is most likely
        // to be running in and naming: its own.
        for keyboard in [SpoolPaneState.Keyboard.here, .inItsSlot, .elsewhere] {
            XCTAssertNil(
                SpoolNamePolicy.refusal(for: request(), pane: state(.unnamed, keyboard: keyboard)),
                "naming must not consult the keyboard, and \(keyboard) is where it is")
        }
    }

    func testALivePaneIsNamedWithoutAnythingExplicit() {
        // `CloseRequest.force`'s question does not arise either — the fixture's pids really do
        // read as busy, and a policy that had copied `SpoolClosePolicy` across would refuse the
        // pane with an agent running in it, which is the pane most worth naming.
        let busy = state(.unnamed)
        XCTAssertTrue(busy.isBusy, "the fixture must really look busy for this to prove anything")
        XCTAssertNil(SpoolNamePolicy.refusal(for: request(), pane: busy))
    }

    func testACanvasIsNamedExactlyAsATerminalIs() {
        // One `Pane.id` namespace (#284), and nothing in this rule asks what the pane holds.
        XCTAssertNil(
            SpoolNamePolicy.refusal(
                for: request(), pane: state(.unnamed, holdsTerminal: false)))
        XCTAssertNotNil(
            SpoolNamePolicy.refusal(
                for: request(), pane: state(.chosen("the plan"), holdsTerminal: false)))
    }

    // MARK: - What is refused

    func testAPaneHelmDoesNotHaveIsRefusedByName() {
        // Never silently nothing: "helm named no pane" and "helm is not running" must not look the
        // same, which is the silence this whole ladder exists to remove.
        let refusal = SpoolNamePolicy.refusal(for: request(), pane: nil)
        XCTAssertEqual(refusal?.reason.contains(pane.uuidString), true)
    }

    func testAPaneSomebodyHasNamedIsRefusedAndTheRefusalSaysWhatItIsCalled() {
        // The operator's ruling: "by default they dont rename if editing existing". The refusal
        // has to carry the current name, because that is the fact the caller has to put in front
        // of the operator to get permission it does not have.
        let refusal = SpoolNamePolicy.refusal(
            for: request(), pane: state(.chosen("watching the deploy")))
        XCTAssertEqual(refusal?.reason.contains("watching the deploy"), true)
        XCTAssertEqual(
            refusal?.reason.contains("rename"), true,
            "…and it names the route: the flag that says the operator asked")
    }

    func testARenameThatSaysTheOperatorAskedIsAllowed() {
        // "…but i can ask for a rename". Not checkable and not pretended to be — the same shape
        // `CloseRequest.force` has, and it defaults to off for the same reason.
        XCTAssertNil(
            SpoolNamePolicy.refusal(
                for: request(rename: true), pane: state(.chosen("watching the deploy"))))
    }

    func testRenameIsHarmlessOnAPaneThatNeededNoPermission() {
        // A superset rather than a mode: a caller that always passes the flag is not punished for
        // it, because there was nothing to protect.
        XCTAssertNil(SpoolNamePolicy.refusal(for: request(rename: true), pane: state(.unnamed)))
        XCTAssertNil(
            SpoolNamePolicy.refusal(
                for: request(rename: true), pane: state(.derived("claude · helm"))))
    }

    // MARK: - The invariant the type carries

    func testTextReadsThroughBothNamedCasesAndNothingElse() {
        // `TerminalSession.displayTitle` and `CanvasTab` both spend `text` and neither has an
        // opinion about provenance, so this is what keeps a rendering question out of the policy's
        // vocabulary — and what makes "no name" unconstructable with a string in it.
        XCTAssertNil(PaneName.unnamed.text)
        XCTAssertEqual(PaneName.derived("claude · helm").text, "claude · helm")
        XCTAssertEqual(PaneName.chosen("the plan").text, "the plan")
    }
}
