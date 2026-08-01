import XCTest

@testable import Helm

/// What a relaunch actually gets back.
///
/// `WorkspaceContextTests` covers the store's round trip in isolation; this covers the
/// step before it — whether `saveContext` captures the tab row that is really open. That
/// seam had no test, and the first live restart after it shipped restored one terminal
/// out of three.
@MainActor
final class ContextPersistenceTests: XCTestCase {
    private let workspacePath = "/tmp/helm-persist-tests"

    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "helm-persist-tests-\(UUID().uuidString)"))
    }

    func testSaveContextCapturesEveryOpenTerminalInOrder() throws {
        let manager = TerminalManager()
        manager.activate(workspacePath: workspacePath)
        manager.newTerminal()
        manager.newTerminal()
        let live = manager.sessions(for: workspacePath).map(\.id)
        XCTAssertEqual(live.count, 3, "precondition: three terminals are open")

        let defaults = try isolatedDefaults()
        let model = WorkspaceModel(defaults: defaults)
        model.open(Workspace(path: workspacePath))
        model.saveContext(terminalManager: manager, artifact: ArtifactPaneModel())

        XCTAssertEqual(
            model.contexts[workspacePath]?.terminalSessionIDs, live,
            "a relaunch must rebuild every open terminal, in order — not just the first")
    }

    /// The bug that actually broke restore, and the only one here with live evidence.
    ///
    /// A `@Published` projection republishes its current value the instant something
    /// subscribes, so `onReceive(artifact.$source)` fired during the first body evaluation
    /// — before `.task` had activated the workspace. That save saw zero sessions and wrote
    /// an empty tab row over the one restore was about to read, so a relaunch always came
    /// back with one fresh shell. Instrumented and confirmed: the context loaded with one
    /// id and reached `activate` with none.
    func testSavingBeforeTheWorkspaceIsMountedDoesNotWipeItsSavedRow() throws {
        let defaults = try isolatedDefaults()
        let saved = WorkspaceContext(
            terminalSessionIDs: [UUID(), UUID()], selectedTerminalID: nil)
        WorkspaceContextStore.save([workspacePath: saved], to: defaults)

        let model = WorkspaceModel(defaults: defaults)
        model.open(Workspace(path: workspacePath))
        // A manager that has never activated this workspace — exactly the state at launch,
        // between the first render and `.task`.
        model.saveContext(terminalManager: TerminalManager(), artifact: ArtifactPaneModel())

        XCTAssertEqual(
            model.contexts[workspacePath]?.terminalSessionIDs, saved.terminalSessionIDs,
            "a save before the workspace is mounted must not overwrite what restore needs")
    }

    /// The wiring, not just the write.
    ///
    /// This is the test the bug could not have had: while the subscription lived in
    /// `RootView` it was unreachable from `swift test`, and both attempts there failed
    /// silently — one persisted a row one change behind, the other crashed the app on
    /// `AsyncPublisher` demand. Moving it onto the model is what made it testable, and
    /// that is most of the argument for putting it there.
    func testObservingTerminalsPersistsEachOneAsItOpens() async throws {
        let manager = TerminalManager()
        let defaults = try isolatedDefaults()
        let model = WorkspaceModel(defaults: defaults)
        model.open(Workspace(path: workspacePath))
        model.observeTerminals(manager, artifact: ArtifactPaneModel())

        manager.activate(workspacePath: workspacePath)
        manager.newTerminal()
        manager.newTerminal()
        // The subscription hops through the main queue on purpose — @Published fires in
        // willSet, so a synchronous read would see the array from before the change.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            model.contexts[workspacePath]?.terminalSessionIDs,
            manager.sessions(for: workspacePath).map(\.id),
            "every terminal that opened must be in the persisted row, not all but the last")
    }

    /// The bug this file was written for: the persist ran while the manager still held
    /// its previous array, so the row saved was always one change behind.
    func testSaveContextSeesATerminalAddedImmediatelyBefore() throws {
        let manager = TerminalManager()
        manager.activate(workspacePath: workspacePath)
        let defaults = try isolatedDefaults()
        let model = WorkspaceModel(defaults: defaults)
        model.open(Workspace(path: workspacePath))

        manager.newTerminal()
        model.saveContext(terminalManager: manager, artifact: ArtifactPaneModel())

        XCTAssertEqual(
            model.contexts[workspacePath]?.terminalSessionIDs.count, 2,
            "saving right after a terminal opens must include it")
        XCTAssertEqual(
            model.contexts[workspacePath]?.selectedTerminalID, manager.selectedID,
            "and the selection must be the one that is actually selected")
    }
}
