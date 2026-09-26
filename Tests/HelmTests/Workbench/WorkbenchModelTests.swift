import Combine
import HelmWire
import XCTest

@testable import Helm

/// The resolver at the edge: benchd's document in, live objects out — and the visibility push
/// that replaced `TerminalManager.selectedID`.
///
/// Against a toy benchd (`ToyBench`), so still no window. Where a pane lands and who gets the
/// keyboard are benchd's rules and are tested there (`bench-doc`'s `placement.rs`, `offer.rs`,
/// `workbench.rs`); what is here is what helm does with the document it is sent.
@MainActor
final class WorkbenchModelTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-workbench-model")
    private let other = WorkspacePath("/tmp/helm-workbench-model-other")

    private func mounted(
        _ panes: [BenchDocument.Pane] = [ToyBench.terminal()], selected: UUID? = nil
    ) throws -> ToyRig {
        var bench = ToyBench.bench(panes)
        if let selected { bench.columns[0].slots[0].selected = selected }
        return try toyRig(
            document: BenchDocument(
                workspaces: [.init(path: workspace.value, bench: bench)],
                active: workspace.value))
    }

    private func open(_ path: String, in rig: ToyRig) throws -> Pane.ID {
        try XCTUnwrap(
            rig.model.send(.paneOpen(surface: .canvas(path: path)), by: .operatorGesture))
    }

    // MARK: - Terminals

    func testEveryTerminalPaneOnScreenGetsASessionUnderItsOwnID() throws {
        let ids = [UUID(), UUID()]
        let rig = try mounted(ids.map { ToyBench.terminal($0) })

        XCTAssertEqual(
            rig.terminals.sessions(for: workspace).map(\.id), ids,
            "a terminal pane's id IS its session id, so a restart is a straight read")
        XCTAssertEqual(rig.model.bench?.terminalPaneIDs, ids)
    }

    func testNoWorkspaceMeansNoBench() throws {
        let rig = try mounted()

        rig.model.send(.workspaceClose(path: workspace.value), by: .operatorGesture)

        XCTAssertNil(
            rig.model.bench,
            "a bench always holds a pane, so 'nothing open' is nil rather than an empty one")
    }

    // MARK: - Resolving

    func testATerminalPaneResolvesToTheManagersSession() throws {
        let rig = try mounted()
        let pane = try XCTUnwrap(rig.model.bench?.panes.first)

        XCTAssertIdentical(
            rig.model.session(for: pane), rig.terminals.sessions(for: workspace).first,
            "the manager still owns every session; the bench only names them")
    }

    func testACanvasPaneResolvesToOneModelPerPaneAndTheSameOneOnReAsk() throws {
        let rig = try mounted()
        let first = Pane(content: .canvas(.file("/tmp/a.md")))
        let second = Pane(content: .canvas(.file("/tmp/b.md")))

        let firstCanvas = rig.model.canvas(for: first)

        XCTAssertIdentical(
            rig.model.canvas(for: first), firstCanvas,
            "re-asking must give back the same webview, not reload the page")
        XCTAssertNotIdentical(
            rig.model.canvas(for: second), firstCanvas, "a second canvas does not evict the first")
    }

    func testClosingACanvasPaneDropsItsModel() throws {
        let rig = try mounted()
        let id = try open("/tmp/a.md", in: rig)
        let pane = try XCTUnwrap(rig.model.bench?.pane(id))
        let canvas = rig.model.canvas(for: pane)

        rig.model.send(.paneClose(id), by: .operatorGesture)

        XCTAssertNotIdentical(
            rig.model.canvas(for: pane), canvas,
            "a retained CanvasModel keeps a FileWatcher, and that watcher an open file "
                + "descriptor, on a file nothing shows")
    }

    /// Closing a workspace takes its panes out of the document, and every canvas it held goes
    /// with them — watcher and descriptor included — whichever workspace is shown next.
    func testClosingAWorkspaceDropsTheCanvasesItOwned() throws {
        let rig = try mounted()
        let id = try open("/tmp/a.md", in: rig)
        let pane = try XCTUnwrap(rig.model.bench?.pane(id))
        let canvas = rig.model.canvas(for: pane)
        rig.model.send(.workspaceOpen(path: other.value), by: .operatorGesture)

        rig.model.send(.workspaceClose(path: workspace.value), by: .operatorGesture)

        XCTAssertNil(rig.terminals.surfaces.existing(id, as: CanvasModel.self))
        XCTAssertNil(canvas.showing, "closed through its kind, not merely dropped")
    }

    /// "Close Workspace" is on every tab's context menu, so the workspace being closed is often
    /// not the one on screen.
    func testClosingABackgroundWorkspaceDropsItsCanvasesAndLeavesTheLiveOneAlone() throws {
        let rig = try mounted()
        let parkedID = try open("/tmp/a.md", in: rig)
        _ = rig.model.canvas(for: try XCTUnwrap(rig.model.bench?.pane(parkedID)))

        rig.model.send(.workspaceOpen(path: other.value), by: .operatorGesture)
        let liveID = try open("/tmp/b.md", in: rig)
        let live = try XCTUnwrap(rig.model.bench?.pane(liveID))
        let liveCanvas = rig.model.canvas(for: live)

        rig.model.send(.workspaceClose(path: workspace.value), by: .operatorGesture)

        XCTAssertNil(rig.terminals.surfaces.existing(parkedID, as: CanvasModel.self))
        XCTAssertIdentical(
            rig.model.canvas(for: live), liveCanvas,
            "the teardown is scoped to one workspace — closing a background tab must not "
                + "reload the canvas the operator is looking at")
    }

    /// A **switch** keeps the model, which is what gets the same webview back instead of
    /// reloading the page: the pane is still in the document.
    func testSwitchingAwayAndBackKeepsTheSameCanvas() throws {
        let rig = try mounted()
        let id = try open("/tmp/a.md", in: rig)
        let pane = try XCTUnwrap(rig.model.bench?.pane(id))
        let canvas = rig.model.canvas(for: pane)

        rig.model.send(.workspaceOpen(path: other.value), by: .operatorGesture)
        rig.model.send(.workspaceActivate(path: workspace.value), by: .operatorGesture)

        XCTAssertEqual(rig.model.workspacePath, workspace)
        XCTAssertIdentical(
            rig.model.canvas(for: pane), canvas,
            "a switch back finds its canvases where it left them")
    }

    // MARK: - Visibility

    func testVisibilityIsPushedOntoExactlyTheOnScreenPanes() throws {
        let under = ToyBench.terminal()
        let shown = ToyBench.terminal()
        // Two TABS in one slot: only one of them is on screen.
        let rig = try mounted([under, shown], selected: shown.id)

        let sessions = rig.terminals.sessions(for: workspace)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertFalse(
            try XCTUnwrap(sessions.first { $0.id == under.id }).isVisible,
            "the tab underneath is not on screen")
        XCTAssertTrue(try XCTUnwrap(sessions.first { $0.id == shown.id }).isVisible)
    }

    func testSplittingMakesBothPanesVisible() throws {
        let rig = try mounted()

        rig.model.send(.paneSplit(direction: .right), by: .operatorGesture)

        XCTAssertEqual(
            rig.terminals.sessions(for: workspace).filter(\.isVisible).count, 2,
            "several terminals are their slot's selection at once — which is what a bench "
                + "means, and what one app-level selectedID could not express")
    }

    /// `reconcileSessions` walks every session in the app, not just this workspace's, because
    /// a background workspace's terminals are off screen by definition.
    func testABackgroundWorkspacesTerminalsAreNotVisible() throws {
        let rig = try mounted()
        let parked = rig.terminals.sessions(for: workspace)

        rig.model.send(.workspaceOpen(path: other.value), by: .operatorGesture)

        XCTAssertEqual(rig.model.workspacePath, other)
        XCTAssertTrue(parked.allSatisfy { !$0.isVisible })
        XCTAssertEqual(
            rig.terminals.sessions(for: workspace).count, parked.count,
            "in the background is not closed — the ptys stay alive")
    }

    /// Every slot showing a canvas, so **zero** ghostty surfaces are attached; what this pins is
    /// that nothing claims to be visible, while the pty behind the tab stays alive.
    func testASlotShowingACanvasLeavesItsTerminalTabsInvisible() throws {
        let terminal = ToyBench.terminal()
        let canvas = BenchDocument.Pane(id: UUID(), surface: .canvas(path: "/tmp/a.md"))
        let rig = try mounted([terminal, canvas], selected: canvas.id)

        XCTAssertEqual(rig.terminals.sessions(for: workspace).filter(\.isVisible).count, 0)
        XCTAssertEqual(rig.terminals.sessions(for: workspace).map(\.id), [terminal.id])
    }

    // MARK: - A terminal's links and pushes

    /// A ⌘-click on a file link, from the session's own callback to benchd: the operator's
    /// `pane/open` of that file. Driven from the session because the hop between the two is the
    /// part that changed shape — it was a broadcast every model heard.
    func testAClickedLinkIsTheOperatorsOpenOfThatFile() throws {
        let rig = try mounted()
        let session = try XCTUnwrap(rig.terminals.sessions.first)

        session.terminalDidRequestOpenURL("file:///tmp/offered.md", kind: .unknown)

        let sent = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual(sent["verb"] as? String, "pane/open")
        XCTAssertEqual((sent["by"] as? [String: Any])?["kind"] as? String, "operator")
        XCTAssertEqual(
            rig.model.bench?.canvasPanes.map(\.content), [.canvas(.file("/tmp/offered.md"))])
    }

    /// A push fires from terminal OUTPUT, so it can arrive from a session in a workspace the
    /// operator left hours ago. The verb names the pushing session's workspace, and that is the
    /// only thing standing between a background build and whatever bench happens to be open.
    func testAPushNamesThePushingSessionsWorkspaceAndIsAnAgents() throws {
        let rig = try mounted()
        let session = try XCTUnwrap(rig.terminals.sessions.first)

        session.terminalDidRequestDesktopNotification(
            title: CanvasPush.marker, body: "/tmp/push.md")

        let sent = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual((sent["args"] as? [String: Any])?["workspace"] as? String, workspace.value)
        XCTAssertEqual((sent["by"] as? [String: Any])?["kind"] as? String, "agent")
        XCTAssertEqual(
            rig.model.bench?.canvasPanes.map(\.content), [.canvas(.file("/tmp/push.md"))],
            "a push from the workspace on screen reaches its bench")
    }

    /// The negative half: a route that ignored the workspace would pass the test above for
    /// free. Only a push from a session in a workspace that is NOT on screen catches it.
    func testAPushFromABackgroundWorkspaceDoesNotLandOnTheOpenBench() throws {
        let rig = try mounted()
        rig.model.send(.workspaceOpen(path: other.value), by: .operatorGesture)
        let parked = try XCTUnwrap(rig.terminals.sessions(for: workspace).first)

        parked.terminalDidRequestDesktopNotification(
            title: CanvasPush.marker, body: "/tmp/push.md")

        XCTAssertEqual(rig.model.workspacePath, other)
        XCTAssertEqual(
            rig.model.bench?.canvasPanes.count, 0,
            "a push from a workspace nobody is looking at must not seize the open bench")
        let pushed = rig.model.document?.workspace(at: workspace)?.bench.columns
            .flatMap(\.slots).flatMap(\.panes).map(\.surface)
        XCTAssertEqual(pushed?.last, .canvas(path: "/tmp/push.md"), "…it lands on its own")
    }

    // MARK: - Closing

    func testClosingATerminalPaneAlsoClosesItsShell() throws {
        let kept = ToyBench.terminal()
        let closing = ToyBench.terminal()
        let rig = try mounted([kept, closing])

        rig.model.send(.paneClose(closing.id), by: .operatorGesture)

        XCTAssertEqual(
            rig.terminals.sessions.map(\.id), [kept.id],
            "the pane leaving the document is what drops the manager's last strong reference")
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

    /// Select-by-index is by position **within the focused slot**, and the bounds guard is the
    /// whole of what makes a stray ⌘9 harmless.
    func testSelectingATabByIndexPicksWithinTheFocusedSlot() throws {
        let panes = [ToyBench.terminal(), ToyBench.terminal()]
        let rig = try mounted(panes)

        pressTab(0, on: rig.model)
        XCTAssertEqual(rig.model.bench?.focusedPane?.id, panes[0].id)

        pressTab(1, on: rig.model)
        XCTAssertEqual(rig.model.bench?.focusedPane?.id, panes[1].id)
    }

    func testSelectingATabOutOfRangeSendsNothing() throws {
        let rig = try mounted()
        let before = rig.server.verbs.count

        pressTab(8, on: rig.model)
        pressTab(-1, on: rig.model)

        XCTAssertEqual(
            rig.server.verbs.count, before, "⌘9 over a slot with one tab is a no-op, not a verb")
    }

    /// ⌘1–⌘9 acts on the focused slot, so a split changes what it means.
    func testSelectingATabIgnoresTabsInOtherSlots() throws {
        let panes = [ToyBench.terminal(), ToyBench.terminal()]
        let rig = try mounted(panes)
        rig.model.send(.paneSplit(direction: .right), by: .operatorGesture)
        let split = try XCTUnwrap(rig.model.bench?.focusedPane?.id)
        let before = rig.server.verbs.count

        pressTab(1, on: rig.model)

        XCTAssertEqual(
            rig.server.verbs.count, before,
            "the new slot holds one pane, so index 1 names nothing in it — and must not "
                + "reach back into the slot ⌘2 would have hit a moment ago")
        XCTAssertEqual(rig.model.bench?.focusedPane?.id, split)
    }
}
