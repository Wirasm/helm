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
