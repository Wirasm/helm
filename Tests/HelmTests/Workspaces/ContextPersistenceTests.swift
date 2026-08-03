import XCTest

@testable import Helm

/// What a relaunch actually gets back.
///
/// `WorkspaceContextTests` covers the store's round trip in isolation; this covers the
/// step before it — whether `saveContext` captures the arrangement that is really open.
/// That seam had no test, and the first live restart after it shipped restored one
/// terminal out of three.
///
/// One field carries all of it now. The assertions read through `context.workbench`
/// rather than `terminalSessionIDs`, and the rules they pin are unchanged.
@MainActor
final class ContextPersistenceTests: XCTestCase {
    private let workspacePath = "/tmp/helm-persist-tests"

    private func mounted(_ manager: TerminalManager) -> WorkbenchModel {
        let workbench = WorkbenchModel(terminals: manager)
        workbench.activate(workspacePath: workspacePath)
        return workbench
    }

    func testSaveContextCapturesEveryOpenTerminalInOrder() throws {
        let manager = TerminalManager()
        let workbench = mounted(manager)
        workbench.newTerminal()
        workbench.newTerminal()
        let live = manager.sessions(for: workspacePath).map(\.id)
        XCTAssertEqual(live.count, 3, "precondition: three terminals are open")

        let defaults = try isolatedDefaults("persist")
        let model = WorkspaceModel(defaults: defaults)
        model.open(Workspace(path: workspacePath))
        model.saveContext(terminalManager: manager, workbench: workbench)

        XCTAssertEqual(
            model.contexts[workspacePath]?.workbench?.terminalPaneIDs, live,
            "a relaunch must rebuild every open terminal, in order — not just the first")
    }

    func testSaveContextRecordsWhichCanvasHeldWhichURL() throws {
        let manager = TerminalManager()
        let workbench = mounted(manager)
        let localhost = URL(string: "http://localhost:3000")!
        workbench.open(.url(localhost))

        let defaults = try isolatedDefaults("persist")
        let model = WorkspaceModel(defaults: defaults)
        model.open(Workspace(path: workspacePath))
        model.saveContext(terminalManager: manager, workbench: workbench)

        XCTAssertEqual(
            model.contexts[workspacePath]?.workbench?.canvasPanes.map(\.content),
            [.canvas(.url(localhost))],
            "a URL canvas persists at last — openArtifactPath could only ever hold a file path")
    }

    /// The bug that actually broke restore, and the only one here with live evidence.
    ///
    /// A `@Published` projection republishes its current value the instant something
    /// subscribes, so a save fired during the first body evaluation — before `.task` had
    /// activated the workspace. That save saw zero sessions and wrote an empty tab row over
    /// the one restore was about to read, so a relaunch always came back with one fresh
    /// shell. Instrumented and confirmed: the context loaded with one id and reached
    /// `activate` with none.
    ///
    /// The bench has the same failure available to it, so it has the same guard.
    func testSavingBeforeTheWorkspaceIsMountedDoesNotWipeItsSavedRow() throws {
        let defaults = try isolatedDefaults("persist")
        let ids = [UUID(), UUID()]
        let saved = WorkspaceContext(
            workbench: Workbench(
                panes: ids.map { Pane(id: $0, content: .terminal(face: .terminal)) }))
        WorkspaceContextStore.save([workspacePath: saved], to: defaults)

        let model = WorkspaceModel(defaults: defaults)
        model.open(Workspace(path: workspacePath))
        // A manager and a bench that have never activated this workspace — exactly the
        // state at launch, between the first render and `.task`.
        let manager = TerminalManager()
        model.saveContext(
            terminalManager: manager, workbench: WorkbenchModel(terminals: manager))

        XCTAssertEqual(
            model.contexts[workspacePath]?.workbench?.terminalPaneIDs, ids,
            "a save before the workspace is mounted must not overwrite what restore needs")
    }

    /// The wiring, not just the write.
    ///
    /// This is the test the bug could not have had: while the subscription lived in
    /// `RootView` it was unreachable from `swift test`, and both attempts there failed
    /// silently — one persisted a row one change behind, the other crashed the app on
    /// `AsyncPublisher` demand. Moving it onto the model is what made it testable, and
    /// that is most of the argument for putting it there.
    func testObservingPersistsEachPaneAsItOpens() async throws {
        let manager = TerminalManager()
        let defaults = try isolatedDefaults("persist")
        let model = WorkspaceModel(defaults: defaults)
        model.open(Workspace(path: workspacePath))
        let workbench = WorkbenchModel(terminals: manager)
        model.observe(terminals: manager, workbench: workbench)

        workbench.activate(workspacePath: workspacePath)
        workbench.newTerminal()
        workbench.newTerminal()
        // The subscription hops through the main queue on purpose — @Published fires in
        // willSet, so a synchronous read would see the array from before the change.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            model.contexts[workspacePath]?.workbench?.terminalPaneIDs,
            manager.sessions(for: workspacePath).map(\.id),
            "every terminal that opened must be in the persisted bench, not all but the last")
    }

    /// A split is an arrangement change with no terminal-count change of its own to
    /// notice, so it is the case the manager's publisher alone would miss.
    func testObservingPersistsAnArrangementChange() async throws {
        let manager = TerminalManager()
        let defaults = try isolatedDefaults("persist")
        let model = WorkspaceModel(defaults: defaults)
        model.open(Workspace(path: workspacePath))
        let workbench = WorkbenchModel(terminals: manager)
        model.observe(terminals: manager, workbench: workbench)

        workbench.activate(workspacePath: workspacePath)
        workbench.splitRight()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            model.contexts[workspacePath]?.workbench?.columns.count, 2,
            "the columns must come back, not just the terminals in them")
    }

    /// The change that starts OUTSIDE the bench's own commands. Every other case here
    /// begins with a `WorkbenchModel` method; this one begins in a live `CanvasModel` — the
    /// operator typing an address into a canvas ⌘L opened — and has to reach the store
    /// through the same sink. It did not, and the page rendered while the bench went on
    /// persisting `{"kind":"empty"}` for it (#89).
    func testObservingPersistsAnAddressCommittedInACanvas() async throws {
        let manager = TerminalManager()
        let defaults = try isolatedDefaults("persist")
        let model = WorkspaceModel(defaults: defaults)
        model.open(Workspace(path: workspacePath))
        let workbench = WorkbenchModel(terminals: manager)
        model.observe(terminals: manager, workbench: workbench)

        workbench.activate(workspacePath: workspacePath)
        let canvas = try XCTUnwrap(workbench.open(.empty))
        workbench.canvas(for: try XCTUnwrap(workbench.bench?.pane(canvas)))
            .submitAddress("localhost:3000")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            model.contexts[workspacePath]?.workbench?.pane(canvas)?.content,
            .canvas(.url(URL(string: "http://localhost:3000")!)),
            "nothing but the canvas changed, so this is the only publisher that could carry "
                + "it — and a saved bench that disagrees with the pane on screen is the bug")
    }

    /// The bug this file was written for: the persist ran while the manager still held
    /// its previous array, so the row saved was always one change behind.
    func testSaveContextSeesATerminalAddedImmediatelyBefore() throws {
        let manager = TerminalManager()
        let workbench = mounted(manager)
        let defaults = try isolatedDefaults("persist")
        let model = WorkspaceModel(defaults: defaults)
        model.open(Workspace(path: workspacePath))

        workbench.newTerminal()
        model.saveContext(terminalManager: manager, workbench: workbench)

        let saved = model.contexts[workspacePath]?.workbench
        XCTAssertEqual(
            saved?.terminalPaneIDs.count, 2, "saving right after a terminal opens must include it")
        XCTAssertEqual(
            saved?.slot(saved!.focusedSlot)?.selected,
            manager.sessions(for: workspacePath).last?.id,
            "and the selection must be the one that is actually selected")
    }
}
