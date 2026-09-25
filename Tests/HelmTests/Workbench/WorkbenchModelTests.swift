import Combine
import HelmWire
import XCTest

@testable import Helm

/// The resolver at the edge: bench values in, live objects out — and the visibility push
/// that replaced `TerminalManager.selectedID`.
///
/// `@MainActor` because the subject is, but still no window: `WorkbenchModel` builds its
/// sessions from an isolated `TerminalManager`, which is what `init(terminals:)` is for.
@MainActor
final class WorkbenchModelTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-workbench-model")
    private let other = WorkspacePath("/tmp/helm-workbench-model-other")

    private func mounted() -> (WorkbenchModel, TerminalManager) {
        let manager = TerminalManager()
        let model = WorkbenchModel(terminals: manager)
        model.activate(workspacePath: workspace)
        return (model, manager)
    }

    // MARK: - Activation

    func testAFirstVisitGetsTodaysOneByOneFrame() throws {
        let (model, manager) = mounted()

        let bench = try XCTUnwrap(model.bench)
        XCTAssertEqual(bench.columns.count, 1)
        XCTAssertEqual(
            bench.terminalPaneIDs, manager.sessions(for: workspace).map(\.id),
            "a workspace with nothing persisted behaves exactly as it always has")
    }

    func testARestoredBenchRebuildsItsTerminalsUnderTheirPersistedIDs() throws {
        let ids = [UUID(), UUID()]
        let restored = Workbench(
            panes: ids.map { Pane(id: $0, content: .terminal()) })
        let manager = TerminalManager()
        let model = WorkbenchModel(terminals: manager)

        model.activate(workspacePath: workspace, restoring: restored)

        XCTAssertEqual(
            manager.sessions(for: workspace).map(\.id), ids,
            "a terminal pane's id IS its session id, so restore is a straight read")
        XCTAssertEqual(model.bench, restored)
    }

    func testNoWorkspaceMeansNoBench() {
        let (model, _) = mounted()

        model.deactivate()

        XCTAssertNil(
            model.bench,
            "a bench always holds a pane, so 'nothing open' is nil rather than an empty one")
    }

    // MARK: - Resolving

    func testATerminalPaneResolvesToTheManagersSession() throws {
        let (model, manager) = mounted()
        let pane = try XCTUnwrap(model.bench?.panes.first)

        XCTAssertIdentical(
            model.session(for: pane), manager.sessions(for: workspace).first,
            "the manager still owns every session; the bench only names them")
    }

    func testACanvasPaneResolvesToOneModelPerPaneAndTheSameOneOnReAsk() {
        let (model, _) = mounted()
        let first = Pane(content: .canvas(.file("/tmp/a.md")))
        let second = Pane(content: .canvas(.file("/tmp/b.md")))

        let firstCanvas = model.canvas(for: first)

        XCTAssertIdentical(
            model.canvas(for: first), firstCanvas,
            "re-asking must give back the same webview, not reload the page")
        XCTAssertNotIdentical(
            model.canvas(for: second), firstCanvas, "a second canvas does not evict the first")
    }

    func testClosingACanvasPaneDropsItsModel() throws {
        let (model, _) = mounted()
        let id = try XCTUnwrap(model.open(.file("/tmp/a.md")))
        let pane = try XCTUnwrap(model.bench?.pane(id))
        let canvas = model.canvas(for: pane)

        model.close(id)

        XCTAssertNotIdentical(
            model.canvas(for: pane), canvas,
            "a retained CanvasModel keeps a FileWatcher, and that watcher an open file "
                + "descriptor, on a file nothing shows")
    }

    /// The per-pane `close` above was the ONLY thing that dropped a canvas. Closing a
    /// whole workspace went through neither it nor `deactivate` — `RootView.closeWorkspace`
    /// reaches `deactivate` only when the closed workspace was selected *and* nothing
    /// replaces it — so every canvas the workspace held stayed cached, watcher and
    /// descriptor with it, for the life of the process.
    func testClosingAWorkspaceDropsTheCanvasesItOwned() throws {
        let (model, _) = mounted()
        let id = try XCTUnwrap(model.open(.file("/tmp/a.md")))
        let pane = try XCTUnwrap(model.bench?.pane(id))
        let canvas = model.canvas(for: pane)

        // The replacement branch: close the selected workspace, activate another. No
        // `deactivate` anywhere in it.
        model.closeWorkspace(workspace)
        model.activate(workspacePath: other)

        XCTAssertNotIdentical(
            model.canvas(for: pane), canvas,
            "the workspace is gone, so nothing can ever show this canvas again — holding "
                + "its watcher's file descriptor open is a leak with no way back to it")
    }

    /// "Close Workspace" is on every tab's context menu, so the workspace being closed is
    /// often not the selected one — the path where `wasSelected` is false and, before the
    /// teardown existed, the bench was not consulted at all.
    func testClosingABackgroundWorkspaceDropsItsCanvasesAndLeavesTheLiveOneAlone() throws {
        let (model, _) = mounted()
        let parkedID = try XCTUnwrap(model.open(.file("/tmp/a.md")))
        let parked = try XCTUnwrap(model.bench?.pane(parkedID))
        let parkedCanvas = model.canvas(for: parked)

        model.activate(workspacePath: other)
        let liveID = try XCTUnwrap(model.open(.file("/tmp/b.md")))
        let live = try XCTUnwrap(model.bench?.pane(liveID))
        let liveCanvas = model.canvas(for: live)

        model.closeWorkspace(workspace)

        XCTAssertNotIdentical(model.canvas(for: parked), parkedCanvas)
        XCTAssertIdentical(
            model.canvas(for: live), liveCanvas,
            "the teardown is scoped to one workspace — closing a background tab must not "
                + "reload the canvas the operator is looking at")
    }

    /// The other half of the rule, and the reason the teardown is on `closeWorkspace`
    /// rather than on `activate`: a **switch** deliberately keeps the cache, which is what
    /// gets the same webview back instead of reloading the page.
    func testSwitchingAwayAndBackKeepsTheSameCanvas() throws {
        let (model, _) = mounted()
        let id = try XCTUnwrap(model.open(.file("/tmp/a.md")))
        let pane = try XCTUnwrap(model.bench?.pane(id))
        let canvas = model.canvas(for: pane)
        let bench = try XCTUnwrap(model.bench)

        model.activate(workspacePath: other)
        model.activate(workspacePath: workspace, restoring: bench)

        XCTAssertIdentical(
            model.canvas(for: pane), canvas,
            "pane ids are persisted, so a switch back finds its canvases where it left them")
    }

    func testAnAlreadyOpenSourceIsSelectedRatherThanDuplicated() throws {
        let (model, _) = mounted()
        let source = CanvasSource.file("/tmp/plan.md")
        let first = try XCTUnwrap(model.open(source))

        let again = model.open(source)

        XCTAssertEqual(again, first, "⌘-clicking the same link twice is one canvas")
        XCTAssertEqual(model.bench?.canvasPanes.count, 1)
    }

    // MARK: - A spawn from outside (#177)

    func testASpawnedTerminalGetsAPaneOfItsOwnRatherThanATabOnTheCanvas() throws {
        let (model, _) = mounted()
        model.open(.file("/tmp/plan.md"))  // the operator ⌘-clicks a link and reads it
        let canvasSlot = try XCTUnwrap(model.bench?.focusedSlot)

        let spawned = try XCTUnwrap(model.spawnTerminal())

        let bench = try XCTUnwrap(model.bench)
        let slot = try XCTUnwrap(bench.slot(for: spawned.id))
        XCTAssertNotEqual(
            slot.id, canvasSlot, "the agent stacked onto the canvas being read (#177)")
        XCTAssertEqual(slot.panes.map(\.id), [spawned.id], "a pane of its own, not a tab")
        XCTAssertTrue(
            spawned.isVisible,
            "a spawn nobody is watching has to be the thing that is visible")
    }

    func testASpawnDoesNotMoveFocusOrChangeWhatASlotIsShowing() throws {
        let (model, _) = mounted()
        model.newTerminal()  // a second tab, so there is a selection a spawn could disturb
        let focused = try XCTUnwrap(model.bench?.focusedSlot)
        let reading = try XCTUnwrap(model.bench?.focusedPane?.id)

        model.spawnTerminal()

        XCTAssertEqual(
            model.bench?.focusedSlot, focused,
            "focus is what every bench command acts on, and the keyboard follows it — a "
                + "spawn that takes it while the operator is typing is worse than a hidden tab")
        XCTAssertEqual(
            model.bench?.focusedPane?.id, reading,
            "and the pane they were typing in is still the one on screen")
    }

    /// Repeated spawns append a column on the right rather than stacking rows into the first
    /// terminal column, so the vertical space the operator is working in is never reflowed.
    /// The columns land on equal widths, because `Workbench.offer` gives each newcomer an
    /// equal share that `normalize()` preserves.
    func testRepeatedSpawnsAppendColumnsOnTheRightAndShareWidthEqually() throws {
        let (model, _) = mounted()
        let firstPane = try XCTUnwrap(model.bench?.panes.first?.id)
        let focused = try XCTUnwrap(model.bench?.focusedSlot)

        let first = try XCTUnwrap(model.spawnTerminal())
        XCTAssertEqual(model.bench?.columns.count, 2, "one spawn, one new column")
        XCTAssertEqual(
            model.bench?.columns.map { $0.slots.flatMap(\.panes).count }, [1, 1],
            "a column of its own, not a second row under the first column")

        let second = try XCTUnwrap(model.spawnTerminal())
        let bench = try XCTUnwrap(model.bench)
        XCTAssertEqual(bench.columns.count, 3, "a second spawn appends a second column")
        XCTAssertEqual(
            bench.columns.map { $0.slots.flatMap(\.panes).map(\.id) },
            [[firstPane], [first.id], [second.id]],
            "every existing pane survives in place; the newcomers are to the right")
        for width in bench.columns.map(\.width) {
            XCTAssertEqual(width, 1.0 / 3, accuracy: 1e-9, "columns share width equally")
        }
        XCTAssertEqual(
            model.bench?.focusedSlot, focused,
            "and the keyboard never follows any of them")
    }

    // MARK: - A split from outside (#269)

    /// The model-level twin of `WorkbenchTests`' value-level assertion, and it is not the same
    /// test: `Workbench.splitRight(offering:)` proves the *bench value* leaves `focusedSlot`
    /// alone, and this proves the method the spool actually calls does too — including that it
    /// mints a real session and reports it, which is what `SpoolResult.terminalId` carries and
    /// what a caller hands to `helm-close` next.
    func testAnOfferedSplitRightMakesAPaneAndLeavesTheKeyboardWhereItWas() throws {
        let (model, _) = mounted()
        let focused = try XCTUnwrap(model.bench?.focusedSlot)
        let reading = try XCTUnwrap(model.bench?.focusedPane?.id)

        let made = try XCTUnwrap(model.offerSplitRight())

        XCTAssertEqual(model.bench?.columns.count, 2, "the column is there")
        XCTAssertNotNil(model.bench?.pane(made.id), "…and it holds the session that was made")
        XCTAssertEqual(
            model.bench?.focusedSlot, focused,
            "an agent's ⌘D must not take the keyboard — the operator may be mid-sentence in "
                + "the column being split")
        XCTAssertEqual(model.bench?.focusedPane?.id, reading, "…and still see their own pane")
    }

    func testAnOfferedSplitDownMakesAPaneAndLeavesTheKeyboardWhereItWas() throws {
        let (model, _) = mounted()
        let focused = try XCTUnwrap(model.bench?.focusedSlot)

        let made = try XCTUnwrap(model.offerSplitDown())

        XCTAssertEqual(model.bench?.columns.first?.slots.count, 2, "the row is there")
        XCTAssertNotNil(model.bench?.pane(made.id))
        XCTAssertEqual(model.bench?.focusedSlot, focused, "and the keyboard did not follow it")
    }

    /// **A control, and named as one: it passes either way.** The cheapest way to make the two
    /// tests above green is to stop every split from focusing, which would break ⌘D for the
    /// operator — the case that is supposed to seize, because they asked for it.
    func testTheOperatorsSplitStillTakesFocusAtTheModelLevel() throws {
        let (model, _) = mounted()
        let focused = try XCTUnwrap(model.bench?.focusedSlot)

        model.splitRight()

        XCTAssertNotEqual(model.bench?.focusedSlot, focused, "⌘D still moves the keyboard")
    }

    // MARK: - Visibility

    func testVisibilityIsPushedOntoExactlyTheOnScreenPanes() throws {
        let (model, manager) = mounted()
        let firstPane = try XCTUnwrap(model.bench?.panes.first)
        model.newTerminal()  // a second TAB in the same slot: only one of them is on screen

        let sessions = manager.sessions(for: workspace)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertFalse(
            try XCTUnwrap(model.session(for: firstPane)).isVisible,
            "the tab underneath is not on screen")
        XCTAssertTrue(try XCTUnwrap(sessions.last).isVisible, "the selected tab is")
    }

    func testSplittingMakesBothPanesVisible() {
        let (model, manager) = mounted()

        model.splitRight()

        XCTAssertEqual(
            manager.sessions(for: workspace).filter(\.isVisible).count, 2,
            "several terminals are their slot's selection at once — which is what a bench "
                + "means, and what one app-level selectedID could not express")
    }

    /// `reconcileSessions` walks every session in the app, not just this workspace's,
    /// because a parked workspace's terminals are off screen by definition.
    func testAParkedWorkspacesTerminalsAreNotVisible() {
        let manager = TerminalManager()
        let model = WorkbenchModel(terminals: manager)
        model.activate(workspacePath: workspace)
        let parked = manager.sessions(for: workspace)

        model.activate(workspacePath: other)

        XCTAssertTrue(parked.allSatisfy { !$0.isVisible })
        XCTAssertEqual(
            manager.sessions(for: workspace).count, parked.count,
            "parked is not closed — the ptys stay alive")
    }

    /// The state today's frame cannot reach and a bench can: every slot showing a canvas,
    /// so **zero** ghostty surfaces are attached. The spike measured that the parked ptys
    /// keep running; what this pins is that nothing claims to be visible.
    func testASlotShowingACanvasLeavesItsTerminalTabsInvisible() throws {
        let terminal = UUID()
        let canvas = Pane(content: .canvas(.file("/tmp/a.md")))
        let restored = Workbench(
            panes: [Pane(id: terminal, content: .terminal()), canvas],
            selecting: canvas.id)
        let manager = TerminalManager()
        let model = WorkbenchModel(terminals: manager)

        model.activate(workspacePath: workspace, restoring: restored)

        XCTAssertEqual(
            manager.sessions(for: workspace).filter(\.isVisible).count, 0,
            "a slot showing its canvas tab has no terminal on screen")
        XCTAssertEqual(
            manager.sessions(for: workspace).map(\.id), [terminal],
            "…and the pty behind that tab is still alive")
    }

    // MARK: - The commands that moved off TerminalWorkspace and CanvasModel

    /// A ⌘-click on a file link in a terminal, from the session's own callback to the bench: it
    /// is the operator's `pane/open`, placed by the bench. Driven from the session because the
    /// hop between the two is the part that changed shape — it was a broadcast every model heard.
    func testAClickedLinkOpensACanvasThroughPlacement() throws {
        let (model, manager) = mounted()
        let session = try XCTUnwrap(manager.sessions.first)

        session.terminalDidRequestOpenURL("file:///tmp/offered.md", kind: .unknown)

        XCTAssertEqual(
            model.bench?.canvasPanes.map(\.content), [.canvas(.file("/tmp/offered.md"))],
            "the link arrives as a verb and placement decides where it lands")
        XCTAssertEqual(model.bench?.columns.count, 2, "…which at 1x1 is a new column")
    }

    // MARK: - Push routing (#227)

    /// A push fires from terminal OUTPUT, so it can arrive from a session in a workspace the
    /// operator parked hours ago. The verb names the pushing session's workspace, and that is
    /// the only thing standing between a background build and whatever bench happens to be
    /// open. Driven from the session's own callback, as `push.sh` reaches it.
    func testAPushNamingTheMountedWorkspaceLands() throws {
        let (model, manager) = mounted()
        let session = try XCTUnwrap(manager.sessions.first)

        session.terminalDidRequestDesktopNotification(
            title: CanvasPush.marker, body: "/tmp/push.md")

        XCTAssertEqual(
            model.bench?.canvasPanes.map(\.content), [.canvas(.file("/tmp/push.md"))],
            "a push from the workspace on screen has to reach its bench")
    }

    /// The negative half, and the one that matters: a route that ignored the workspace would
    /// pass the test above for free. Only a push from a session in a workspace that is NOT
    /// mounted, asserted to land nowhere on the open bench, catches that.
    func testAPushFromAnUnmountedWorkspaceDoesNotLandOnTheOpenBench() {
        let (model, manager) = mounted()
        let parked = manager.newTerminal(in: other)

        parked.terminalDidRequestDesktopNotification(
            title: CanvasPush.marker, body: "/tmp/push.md")

        XCTAssertEqual(
            model.bench?.canvasPanes.count, 0,
            "a push from a workspace nobody is looking at must not seize the open bench")
    }

    // MARK: - Closing

    func testClosingATerminalPaneAlsoClosesItsShell() throws {
        let (model, manager) = mounted()
        model.newTerminal()
        let closing = try XCTUnwrap(model.bench?.panes.last?.id)

        model.close(closing)

        XCTAssertFalse(
            manager.sessions.contains { $0.id == closing },
            "the pane going away is what drops the manager's last strong reference")
    }

    /// The manager no longer refuses its workspace's last terminal — that rule generalised
    /// to the bench's last *pane*. A workspace showing one terminal and one canvas may
    /// legitimately close the terminal.
    func testTheLastTerminalCanCloseWhenACanvasSurvivesIt() throws {
        let (model, manager) = mounted()
        model.open(.file("/tmp/a.md"))
        let terminal = try XCTUnwrap(model.bench?.terminalPaneIDs.first)

        model.close(terminal)

        XCTAssertTrue(manager.sessions(for: workspace).isEmpty)
        XCTAssertEqual(model.bench?.panes.count, 1, "the canvas is still there")
    }

    func testTheLastPaneOfTheBenchStillRefuses() throws {
        let (model, manager) = mounted()
        let only = try XCTUnwrap(model.bench?.panes.first?.id)

        model.close(only)

        XCTAssertEqual(model.bench?.panes.map(\.id), [only])
        XCTAssertEqual(manager.sessions(for: workspace).count, 1, "and its shell is untouched")
    }

    // MARK: - ⌘1–⌘9

    /// ⌘1–⌘9 as the key does it: the table's gesture, resolved against the bench as it is now,
    /// sent as the operator. A tab that is not there resolves to no verb at all.
    private func pressTab(_ index: Int, on model: WorkbenchModel) {
        guard
            let verb = VerbTemplate.showTab(index: index).resolve(
                bench: model.bench, workspaces: [], active: nil)
        else { return }
        model.send(verb, by: .operatorGesture)
    }

    /// The eighth of the tests that moved off `TerminalManager` when selection became the
    /// slot's. Select-by-index changed meaning on the way — it was a position in the
    /// workspace's one row, and a bench has no such row — so it is by position **within the
    /// focused slot**, and the bounds guard is the whole of what makes a stray ⌘9 harmless.
    func testSelectingATabByIndexPicksWithinTheFocusedSlot() throws {
        let (model, _) = mounted()
        model.newTerminal()
        let panes = try XCTUnwrap(model.bench?.slot(try XCTUnwrap(model.bench?.focusedSlot))?.panes)
        XCTAssertEqual(panes.count, 2, "⌘1 and ⌘2 need two tabs to choose between")

        pressTab(0, on: model)
        XCTAssertEqual(model.bench?.focusedPane?.id, panes[0].id)

        pressTab(1, on: model)
        XCTAssertEqual(model.bench?.focusedPane?.id, panes[1].id)
    }

    func testSelectingATabOutOfRangeChangesNothing() throws {
        let (model, _) = mounted()
        pressTab(0, on: model)
        let before = try XCTUnwrap(model.bench)

        pressTab(8, on: model)
        pressTab(-1, on: model)

        XCTAssertEqual(model.bench, before, "⌘9 over a slot with one tab is a no-op, not a crash")
    }

    /// ⌘1–⌘9 acts on the focused slot, so a split changes what it means — the point of
    /// moving it off the manager.
    func testSelectingATabIgnoresTabsInOtherSlots() throws {
        let (model, _) = mounted()
        model.newTerminal()
        let firstSlotPanes = try XCTUnwrap(
            model.bench?.slot(try XCTUnwrap(model.bench?.focusedSlot))?.panes)
        model.splitRight()
        let split = try XCTUnwrap(model.bench?.focusedPane?.id)

        pressTab(1, on: model)

        XCTAssertEqual(
            model.bench?.focusedPane?.id, split,
            "the new slot holds one pane, so index 1 names nothing in it — and must not "
                + "reach back into the slot ⌘2 would have hit a moment ago")
        XCTAssertFalse(
            firstSlotPanes.map(\.id).contains(try XCTUnwrap(model.bench?.focusedPane?.id)))
    }
}
