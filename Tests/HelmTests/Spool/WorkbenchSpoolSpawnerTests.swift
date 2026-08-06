import HelmWire
import XCTest

@testable import Helm

/// `WorkspacePathSpoolAgreementTests` pins that `WorkspacePath` and `SpoolPolicy.accept`
/// normalize a `cwd` identically — the two SIDES of the boundary agreeing on a string. What
/// it does not reach is `WorkbenchSpoolSpawner.openTerminal`'s own gate: having agreed on the
/// string, does a spawn actually land only when it names the workspace helm has mounted.
///
/// `activate` here is a stub rather than real `WorkspaceModel`/`RootView` wiring — this is
/// `WorkbenchSpoolSpawner`'s own decision under test, not whether activation succeeds
/// end-to-end (that is `WorkbenchModelTests`' and the live #226 verification's job).
@MainActor
final class WorkbenchSpoolSpawnerTests: XCTestCase {
    private let mounted = WorkspacePath("/tmp/helm-spool-spawner-mounted")
    private let elsewhere = WorkspacePath("/tmp/helm-spool-spawner-elsewhere")

    private func spawner(
        activate: @escaping @MainActor (Workspace) -> Void = { _ in }
    ) -> (WorkbenchSpoolSpawner, TerminalManager) {
        let terminals = TerminalManager()
        let workbench = WorkbenchModel(terminals: terminals)
        workbench.activate(workspacePath: mounted)
        let spawner = WorkbenchSpoolSpawner(
            workbench: workbench, terminals: terminals, activate: activate)
        return (spawner, terminals)
    }

    /// The matching case: a request naming the workspace already on screen never even needs
    /// `activate` to do anything, and a session comes back.
    func testASpawnNamingTheMountedWorkspaceSucceeds() throws {
        let (spawner, terminals) = spawner()
        let before = terminals.sessions(for: mounted).count

        let result = spawner.openTerminal(cwd: mounted.value)

        guard case let .success(id) = result else {
            return XCTFail("a spawn naming the mounted workspace must succeed, got \(result)")
        }
        XCTAssertEqual(terminals.sessions(for: mounted).count, before + 1)
        XCTAssertTrue(terminals.sessions(for: mounted).contains { $0.id == id })
    }

    /// The negative half: a request naming a workspace helm never actually mounted — the
    /// stub `activate` declines to switch, standing in for a folder that failed to open —
    /// must be refused rather than spawning into whatever IS mounted. A gate that is `true`
    /// unconditionally passes the test above for free; only this catches it.
    func testASpawnNamingAWorkspaceThatNeverBecomesMountedIsRefused() throws {
        let (spawner, terminals) = spawner(activate: { _ in })
        let before = terminals.sessions.count

        let result = spawner.openTerminal(cwd: elsewhere.value)

        guard case let .failure(refusal) = result else {
            return XCTFail("a spawn naming an unmounted workspace must be refused")
        }
        XCTAssertTrue(
            refusal.reason.contains(elsewhere.value),
            "the refusal has to name the workspace it could not use — got: \(refusal.reason)")
        XCTAssertEqual(
            terminals.sessions.count, before,
            "a refused spawn must not have opened a pty anywhere, mounted workspace included")
    }
}
