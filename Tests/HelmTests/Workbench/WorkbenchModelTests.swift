import Combine
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
            panes: ids.map { Pane(id: $0, content: .terminal(face: .terminal)) })
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

    // MARK: - A canvas that goes somewhere takes its pane with it (#89)

    /// The issue's reproduction, from the keystroke. ⌘L opens a canvas at `.empty` because
    /// at that moment there is no address; the operator types one and the page renders — and
    /// the bench used to keep `.empty` for the rest of the session, so a relaunch gave back
    /// a blank canvas labelled "New canvas".
    func testCommittingAnAddressPointsTheCanvasPaneAtTheURL() async throws {
        let (model, _) = mounted()

        // ⌘L carries no payload, which is what tells the model to open the address field.
        HelmCommand.openCanvasURL(nil).post()
        try await Task.sleep(for: .milliseconds(100))
        let pane = try XCTUnwrap(model.bench?.canvasPanes.first)
        XCTAssertEqual(pane.content, .canvas(.empty), "⌘L has nothing to point at yet")

        model.canvas(for: pane).submitAddress("localhost:3000")

        XCTAssertEqual(
            model.bench?.pane(pane.id)?.content,
            .canvas(.url(URL(string: "http://localhost:3000")!)),
            "the address that loaded is what a relaunch has to give back")
    }

    /// The other half of the acceptance: an unset canvas restores empty rather than onto
    /// something the operator never saw.
    func testARefusedAddressLeavesTheCanvasPaneEmpty() throws {
        let (model, _) = mounted()
        let id = try XCTUnwrap(model.open(.empty))
        let pane = try XCTUnwrap(model.bench?.pane(id))

        model.canvas(for: pane).submitAddress("ssh://root@evil.example")

        XCTAssertEqual(
            model.bench?.pane(id)?.content, .canvas(.empty),
            "an address the policy refused never loaded — persisting it would restore the "
                + "canvas onto a page that was never on screen")
    }

    func testAPageThatFollowsALinkTakesItsPaneWithIt() throws {
        let (model, _) = mounted()
        let id = try XCTUnwrap(model.open(.url(URL(string: "http://localhost:3000")!)))
        let pane = try XCTUnwrap(model.bench?.pane(id))

        model.canvas(for: pane).pageDidNavigate(to: URL(string: "http://localhost:3000/status")!)

        XCTAssertEqual(
            model.bench?.pane(id)?.content,
            .canvas(.url(URL(string: "http://localhost:3000/status")!)),
            "the address bar follows a link click so it never lies about what is on screen; "
                + "restore has the same reason")
    }

    /// Every bench change is a `UserDefaults` write, through `WorkspaceModel.observe`. The
    /// events that leave the canvas exactly where it was must not produce one.
    ///
    /// Counted rather than compared, because comparing proves nothing here: repointing a
    /// pane to the source it already has leaves a bench *equal* to the one before it, so an
    /// equality assertion passes whether or not the redundant commit happened — and the
    /// commit is the thing that reaches the store.
    func testAReloadOrAFailureDoesNotRewriteTheBench() throws {
        let (model, _) = mounted()
        let id = try XCTUnwrap(model.open(.url(URL(string: "http://localhost:3000")!)))
        let canvas = model.canvas(for: try XCTUnwrap(model.bench?.pane(id)))
        let before = try XCTUnwrap(model.bench)
        var commits = 0
        let subscription = model.objectWillChange.sink { _ in commits += 1 }
        defer { subscription.cancel() }

        canvas.reloadPage()
        canvas.pageDidFail("Could not connect to the server.")

        XCTAssertEqual(commits, 0, "neither event may reach the store at all")
        XCTAssertEqual(model.bench, before, "…and neither moves the canvas anywhere")
    }

    /// `close(_:)` drops the pane from the bench before it empties the canvas, and an
    /// emptied canvas reports nothing anyway. Both have to hold, because a late callback
    /// from a webview that is going away is exactly when this fires.
    func testALateCallbackFromAClosedCanvasCannotResurrectItsPane() throws {
        let (model, _) = mounted()
        let id = try XCTUnwrap(model.open(.url(URL(string: "http://localhost:3000")!)))
        let canvas = model.canvas(for: try XCTUnwrap(model.bench?.pane(id)))

        model.close(id)
        canvas.pageDidNavigate(to: URL(string: "http://localhost:3000/late")!)

        XCTAssertNil(model.bench?.pane(id), "a closed pane must not come back")
    }

    /// `deactivate` drops the canvas cache without closing what is in it, so a model whose
    /// pane is later re-resolved is still alive and still holding its write-back closure.
    /// Nothing today calls `deactivate` without `closeWorkspace` first — but the write-back
    /// is what made an orphan able to reach the bench at all, so the guard is its own.
    func testAnOrphanedCanvasCannotRepointTheBenchThatReplacedIt() throws {
        let live = URL(string: "http://localhost:3000")!
        let page = Pane(content: .canvas(.url(live)))
        let restored = Workbench(panes: [Pane(content: .terminal(face: .terminal)), page])
        let model = WorkbenchModel(terminals: TerminalManager())
        model.activate(workspacePath: workspace, restoring: restored)
        let orphan = model.canvas(for: page)

        model.deactivate()
        model.activate(workspacePath: workspace, restoring: restored)
        XCTAssertNotIdentical(model.canvas(for: page), orphan, "precondition: it is an orphan")

        orphan.pageDidNavigate(to: URL(string: "http://localhost:3000/zombie")!)

        XCTAssertEqual(
            model.bench?.pane(page.id)?.content, .canvas(.url(live)),
            "a canvas nothing shows any more must not write over the one that does")
    }

    /// The ordering the write-back depends on: a restored pane resolves to a canvas that is
    /// *shown its own source*, and that must not read as the canvas having moved.
    func testResolvingARestoredCanvasDoesNotRewriteItsPane() {
        let page = Pane(content: .canvas(.url(URL(string: "http://localhost:3000/status")!)))
        let restored = Workbench(panes: [Pane(content: .terminal(face: .terminal)), page])
        let model = WorkbenchModel(terminals: TerminalManager())
        model.activate(workspacePath: workspace, restoring: restored)

        _ = model.canvas(for: page)

        XCTAssertEqual(model.bench, restored, "showing a canvas its own source is not a move")
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
            panes: [Pane(id: terminal, content: .terminal(face: .terminal)), canvas],
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

    /// The subscription moved here from `CanvasModel`, and it had to: there is one canvas
    /// model per pane now, so a receiver on the model would make a single ⌘-clicked link
    /// replace the contents of every open canvas at once.
    func testAClickedLinkOpensACanvasThroughPlacement() async throws {
        let (model, _) = mounted()
        let file = URL(fileURLWithPath: "/tmp/offered.md")

        HelmCommand.openCanvasFile(file).post()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            model.bench?.canvasPanes.map(\.content), [.canvas(.file(file))],
            "the offer arrives as a notification and placement decides where it lands")
        XCTAssertEqual(model.bench?.columns.count, 2, "…which at 1x1 is a new column")
    }

    // MARK: - Push routing (#227)

    /// `CanvasPushRequestTests` (`CanvasPushTests.swift`) pins the request TYPE — that two
    /// workspaces asking for the same artifact compare unequal. What it cannot pin is that
    /// `WorkbenchModel` actually acts on that difference: a push fires from terminal OUTPUT,
    /// so it can arrive from a session in a workspace the operator parked hours ago, and the
    /// guard at `WorkbenchModel.handle(.pushCanvasFile:)` is the only thing standing between
    /// that and a background build landing on whatever bench happens to be open.
    func testAPushNamingTheMountedWorkspaceLands() async throws {
        let (model, _) = mounted()

        HelmCommand.pushCanvasFile(
            CanvasPushRequest(
                artifact: URL(fileURLWithPath: "/tmp/push.md"), workspacePath: workspace,
                origin: CanvasOrigin(terminal: UUID()))
        ).post()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            model.bench?.canvasPanes.map(\.content), [.canvas(.file("/tmp/push.md"))],
            "a push naming the workspace on screen has to reach its bench")
    }

    /// The negative half, and the one that matters: a gate that is `true` unconditionally
    /// passes the test above for free. Only a push naming a workspace that is NOT mounted,
    /// asserted to land nowhere, catches that.
    func testAPushNamingAnUnmountedWorkspaceIsDropped() async throws {
        let (model, _) = mounted()

        HelmCommand.pushCanvasFile(
            CanvasPushRequest(
                artifact: URL(fileURLWithPath: "/tmp/push.md"), workspacePath: other,
                origin: CanvasOrigin(terminal: UUID()))
        ).post()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            model.bench?.canvasPanes.count, 0,
            "a push from a workspace nobody is looking at must not seize the open bench")
    }

    func testTheFaceCommandReachesTheModelWhileNoViewHoldsIt() async throws {
        let (model, _) = mounted()

        HelmCommand.toggleChat.post()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            model.bench?.face(ofSelectedPaneIn: try XCTUnwrap(model.bench?.focusedSlot)), .chat,
            "⌘T has to reach a pane whose view may be mounted, unmounted or not yet built")
    }

    // MARK: - The face

    func testTogglingTheFaceReachesTheFocusedPaneAndNothingElse() throws {
        let (model, _) = mounted()
        let firstSlot = try XCTUnwrap(model.bench?.focusedSlot)
        model.splitRight()
        let secondSlot = try XCTUnwrap(model.bench?.focusedSlot)

        model.toggleFace()

        XCTAssertEqual(model.bench?.face(ofSelectedPaneIn: secondSlot), .chat)
        XCTAssertEqual(model.bench?.face(ofSelectedPaneIn: firstSlot), .terminal)
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

    /// The eighth of the tests that moved off `TerminalManager` when selection became the
    /// slot's. Select-by-index changed meaning on the way — it was a position in the
    /// workspace's one row, and a bench has no such row — so it is by position **within the
    /// focused slot**, and the bounds guard is the whole of what makes a stray ⌘9 harmless.
    func testSelectingATabByIndexPicksWithinTheFocusedSlot() throws {
        let (model, _) = mounted()
        model.newTerminal()
        let panes = try XCTUnwrap(model.bench?.slot(try XCTUnwrap(model.bench?.focusedSlot))?.panes)
        XCTAssertEqual(panes.count, 2, "⌘1 and ⌘2 need two tabs to choose between")

        model.selectTab(0)
        XCTAssertEqual(model.bench?.focusedPane?.id, panes[0].id)

        model.selectTab(1)
        XCTAssertEqual(model.bench?.focusedPane?.id, panes[1].id)
    }

    func testSelectingATabOutOfRangeChangesNothing() throws {
        let (model, _) = mounted()
        model.selectTab(0)
        let before = try XCTUnwrap(model.bench)

        model.selectTab(8)
        model.selectTab(-1)

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

        model.selectTab(1)

        XCTAssertEqual(
            model.bench?.focusedPane?.id, split,
            "the new slot holds one pane, so index 1 names nothing in it — and must not "
                + "reach back into the slot ⌘2 would have hit a moment ago")
        XCTAssertFalse(
            firstSlotPanes.map(\.id).contains(try XCTUnwrap(model.bench?.focusedPane?.id)))
    }

    // MARK: - Post

    /// Post's whole routing rule. The ambiguous case is the one that matters: two chat
    /// faces open and no focused one means there is no unambiguous answer, and a `nil`
    /// target is what leaves the button disabled instead of posting into whichever pane
    /// happened to sort first.
    func testPostGoesToTheFocusedPaneWhenItIsOnTheChatFace() throws {
        let (model, _) = mounted()
        model.toggleFace()

        XCTAssertEqual(model.composeTarget, model.bench?.focusedPane?.id)
    }

    func testPostFallsBackToTheOnlyChatFaceOpen() throws {
        let (model, _) = mounted()
        let reading = try XCTUnwrap(model.bench?.focusedPane?.id)
        model.toggleFace()
        model.splitRight()

        XCTAssertEqual(
            model.bench?.face(ofSelectedPaneIn: try XCTUnwrap(model.bench?.focusedSlot)),
            .terminal, "focus moved to the split, which is on the terminal face")
        XCTAssertEqual(
            model.composeTarget, reading,
            "the operator is looking at exactly one piece of writing — that is where notes go")
    }

    func testPostHasNoTargetWhenTwoChatFacesAreOpenAndNeitherIsFocused() throws {
        let (model, _) = mounted()
        model.toggleFace()
        model.splitRight()
        model.toggleFace()
        model.splitDown()

        XCTAssertEqual(model.bench?.canvasPanes.count, 0)
        XCTAssertNil(
            model.composeTarget,
            "two chat faces and a terminal focused — guessing between them would put the "
                + "operator's notes in the wrong agent's composer")
    }

    func testPostHasNoTargetWhenNothingIsReading() {
        let (model, _) = mounted()

        XCTAssertNil(model.composeTarget)
    }

    /// `post` is the gate, not just the messenger: with no target it must send nothing at
    /// all rather than a request no pane will claim.
    func testPostWithNoTargetSendsNothing() {
        let (model, _) = mounted()
        var received: [ComposeRequest] = []
        let token = HelmCommand.publisher.sink {
            if case let .composeText(request) = $0 { received.append(request) }
        }
        defer { token.cancel() }

        model.post("## `#phase-2`\n\nthis ordering is wrong")

        XCTAssertTrue(received.isEmpty)
    }

    func testPostCarriesTheNotesToTheTargetPane() throws {
        let (model, _) = mounted()
        model.toggleFace()
        let target = try XCTUnwrap(model.composeTarget)
        var received: [ComposeRequest] = []
        let token = HelmCommand.publisher.sink {
            if case let .composeText(request) = $0 { received.append(request) }
        }
        defer { token.cancel() }

        model.post("this ordering is wrong")

        XCTAssertEqual(received.map(\.pane), [target])
        XCTAssertEqual(received.map(\.text), ["this ordering is wrong"])
    }
}
