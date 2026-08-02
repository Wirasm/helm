import XCTest

@testable import Helm

/// The resolver at the edge: bench values in, live objects out — and the visibility push
/// that replaced `TerminalManager.selectedID`.
///
/// `@MainActor` because the subject is, but still no window: `WorkbenchModel` builds its
/// sessions from an isolated `TerminalManager`, which is what `init(terminals:)` is for.
@MainActor
final class WorkbenchModelTests: XCTestCase {
    private let workspace = "/tmp/helm-workbench-model"
    private let other = "/tmp/helm-workbench-model-other"

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
        let first = Pane(content: .canvas(.file(path: "/tmp/a.md")))
        let second = Pane(content: .canvas(.file(path: "/tmp/b.md")))

        let firstCanvas = model.canvas(for: first)

        XCTAssertIdentical(
            model.canvas(for: first), firstCanvas,
            "re-asking must give back the same webview, not reload the page")
        XCTAssertNotIdentical(
            model.canvas(for: second), firstCanvas, "a second canvas does not evict the first")
    }

    func testClosingACanvasPaneDropsItsModel() throws {
        let (model, _) = mounted()
        let id = try XCTUnwrap(model.open(.file(path: "/tmp/a.md")))
        let pane = try XCTUnwrap(model.bench?.pane(id))
        let canvas = model.canvas(for: pane)

        model.close(id)

        XCTAssertNotIdentical(
            model.canvas(for: pane), canvas,
            "a retained CanvasModel keeps a FileWatcher, and that watcher an open file "
                + "descriptor, on a file nothing shows")
    }

    func testAnAlreadyOpenSourceIsSelectedRatherThanDuplicated() throws {
        let (model, _) = mounted()
        let source = CanvasSource.file(path: "/tmp/plan.md")
        let first = try XCTUnwrap(model.open(source))

        let again = model.open(source)

        XCTAssertEqual(again, first, "⌘-clicking the same link twice is one canvas")
        XCTAssertEqual(model.bench?.canvasPanes.count, 1)
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

    /// `reconcileVisibility` walks every session in the app, not just this workspace's,
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
        let canvas = Pane(content: .canvas(.file(path: "/tmp/a.md")))
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

        NotificationCenter.default.post(name: .helmOpenCanvasFile, object: file)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            model.bench?.canvasPanes.map(\.content), [.canvas(.file(file))],
            "the offer arrives as a notification and placement decides where it lands")
        XCTAssertEqual(model.bench?.columns.count, 2, "…which at 1x1 is a new column")
    }

    func testTheFaceCommandReachesTheModelWhileNoViewHoldsIt() async throws {
        let (model, _) = mounted()

        NotificationCenter.default.post(name: .helmToggleChat, object: nil)
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
        model.open(.file(path: "/tmp/a.md"))
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
}
