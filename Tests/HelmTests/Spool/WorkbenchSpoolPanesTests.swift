import HelmWire
import XCTest

@testable import Helm

/// The one reading of a live bench that both addressed policies are decided against (#284).
///
/// **`SpoolSelectPolicyTests` proves the rules and cannot prove this.** It is handed a
/// `SpoolPaneState` and asks what the policy says about it; nothing there checks that a real
/// bench ever *produces* `.inItsSlot`, and a `keyboard(for:in:)` that answered `.elsewhere` for
/// every pane would leave every test in that file green while handing an agent the operator's
/// own slot. This is the half that needs a bench — so it builds one, with an isolated
/// `TerminalManager` and no window, exactly as `WorkbenchModelTests` does.
@MainActor
final class WorkbenchSpoolPanesTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-spool-panes")
    private let plan = CanvasSource.file("/tmp/helm-spool-panes-plan.md")

    /// A bench whose focused slot holds the operator's terminal, plus one pushed canvas placed
    /// where the test asks for it — the two arrangements #284 is about.
    private func bench(
        pushing canvas: Pane, at placement: (Workbench) -> Placement
    ) -> (WorkbenchSpoolPanes, WorkbenchModel, UUID) {
        let terminal = UUID()
        var bench = Workbench(panes: [Pane(id: terminal, content: .terminal(face: .terminal))])
        bench.offer(canvas, at: placement(bench))
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals)
        model.activate(workspacePath: workspace, restoring: bench)
        return (
            WorkbenchSpoolPanes(workbench: model, terminals: terminals), model, terminal
        )
    }

    // MARK: - Where the keyboard is, relative to a pane

    func testAPaneInAnotherSlotReportsTheKeyboardElsewhere() {
        let pushed = Pane(content: .canvas(plan))
        let (panes, _, _) = bench(pushing: pushed, at: { _ in .column })

        XCTAssertEqual(panes.pane(pushed.id)?.keyboard, .elsewhere)
    }

    func testABackgroundTabOfTheFocusedSlotReportsTheKeyboardInItsSlot() {
        // **The state that only a real bench can produce, and the one the select rule turns
        // on.** A push into the slot the operator is already in lands the artifact behind their
        // terminal: not the focused pane, and one tab away from being it.
        let pushed = Pane(content: .canvas(plan))
        let (panes, _, _) = bench(pushing: pushed, at: { .tab(in: $0.focusedSlot) })

        XCTAssertEqual(panes.pane(pushed.id)?.keyboard, .inItsSlot)
        XCTAssertEqual(
            panes.pane(pushed.id)?.holdsKeyboard, false,
            "the premise of the whole rule: this pane does NOT hold the keyboard, so a close's "
                + "predicate cannot see it")
    }

    func testThePaneTheOperatorIsInReportsTheKeyboardHere() {
        let pushed = Pane(content: .canvas(plan))
        let (panes, _, terminal) = bench(pushing: pushed, at: { _ in .column })

        XCTAssertEqual(panes.pane(terminal)?.keyboard, .here)
        XCTAssertEqual(panes.pane(terminal)?.holdsKeyboard, true)
    }

    func testAPaneTheBenchDoesNotHoldIsNil() {
        let pushed = Pane(content: .canvas(plan))
        let (panes, _, _) = bench(pushing: pushed, at: { _ in .column })

        XCTAssertNil(panes.pane(UUID()))
    }

    // MARK: - Bringing it forward

    func testShowingAPaneInAnotherSlotMakesItVisibleAndLeavesTheKeyboardAlone() throws {
        // The end of #284's chain, against a real bench: the artifact an agent pushed becomes
        // the one its slot displays, and the operator's next keystroke still lands where it did.
        let pushed = Pane(content: .canvas(plan))
        let sibling = Pane(content: .canvas(.file("/tmp/helm-spool-panes-other.md")))
        var arrangement = Workbench(
            panes: [Pane(id: UUID(), content: .terminal(face: .terminal))])
        arrangement.offer(sibling, at: .column)
        // Behind `sibling`, in a slot the operator is not in — exactly where a re-push lands on
        // a busy bench, and the reason #272's refresh was unobservable.
        let dockSlot = try XCTUnwrap(arrangement.slot(for: sibling.id)?.id)
        arrangement.offer(pushed, at: .tab(in: dockSlot))
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals)
        model.activate(workspacePath: workspace, restoring: arrangement)
        let panes = WorkbenchSpoolPanes(workbench: model, terminals: terminals)
        let focusedBefore = model.bench?.focusedPane?.id

        XCTAssertEqual(
            model.bench?.visiblePaneIDs.contains(pushed.id), false,
            "the premise: it arrived hidden, which is the whole of the issue")

        guard case .success(let report) = panes.select(pushed.id) else {
            return XCTFail("a pane in another slot must be shown")
        }

        XCTAssertTrue(report.isVisible, "and the report says so, read back off the bench")
        XCTAssertEqual(model.bench?.visiblePaneIDs.contains(pushed.id), true)
        XCTAssertEqual(report.pane.uuid, pushed.id)
        XCTAssertEqual(
            report.focusedPaneBefore, report.focusedPaneAfter,
            "the promise `SpoolSelectPolicy` argues, measured either side of the mutation rather "
                + "than asserted")
        XCTAssertEqual(model.bench?.focusedPane?.id, focusedBefore)
    }

    func testShowingAPaneTheBenchDoesNotHoldReportsItAsNotVisible() {
        // `WorkbenchModel.offerSelect` reports the bench's answer, not the request's hope. The
        // policy refuses this case before the adapter sees it, so this is the belt to that
        // brace — and it is what `SpoolModel` turns into a `refused` rather than a `selected`.
        let pushed = Pane(content: .canvas(plan))
        let (panes, _, _) = bench(pushing: pushed, at: { _ in .column })

        guard case .success(let report) = panes.select(UUID()) else {
            return XCTFail("no bench refusal is expected — there is a bench")
        }
        XCTAssertFalse(report.isVisible)
    }

    func testWithNoBenchMountedASelectSaysSoRatherThanReportingSuccess() {
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals)
        let panes = WorkbenchSpoolPanes(workbench: model, terminals: terminals)

        guard case .failure(let refusal) = panes.select(UUID()) else {
            return XCTFail("with nothing open there is no slot to show anything in")
        }
        XCTAssertTrue(refusal.reason.contains("no bench"))
    }
}
