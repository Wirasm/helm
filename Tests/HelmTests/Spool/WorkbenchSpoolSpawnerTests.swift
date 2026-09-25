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
    ) -> (WorkbenchSpoolSpawner, TerminalManager, WorkbenchModel) {
        let terminals = TerminalManager()
        let workbench = WorkbenchModel(terminals: terminals)
        workbench.activate(workspacePath: mounted)
        let spawner = WorkbenchSpoolSpawner(
            workbench: workbench, terminals: terminals, activate: activate)
        return (spawner, terminals, workbench)
    }

    /// The matching case: a request naming the workspace already on screen never even needs
    /// `activate` to do anything, and a session comes back.
    func testASpawnNamingTheMountedWorkspaceSucceeds() throws {
        let (spawner, terminals, _) = spawner()
        let before = terminals.sessions(for: mounted).count

        let result = spawner.openTerminal(cwd: mounted.value, named: .derived("claude · fixture"))

        guard case let .success(id) = result else {
            return XCTFail("a spawn naming the mounted workspace must succeed, got \(result)")
        }
        XCTAssertEqual(terminals.sessions(for: mounted).count, before + 1)
        XCTAssertTrue(terminals.sessions(for: mounted).contains { $0.id == id })
    }

    /// **The boundary the reported defect actually crossed (#177).** `spawnTerminal` versus
    /// `newTerminal` is one call in `openTerminal`, and the placement tests a layer below
    /// (`WorkbenchModelTests`) stay green if that call is swapped: a spawn would stack as a tab
    /// on whatever had focus and take the keyboard, which is the defect the operator reported.
    /// This pins the adapter's own choice — a column on the right, focus unmoved — so a future
    /// swap of that call fails here rather than shipping silently.
    func testASpawnAppendsANewColumnOnTheRightWithoutTakingFocus() throws {
        let (spawner, _, workbench) = spawner()
        let focused = try XCTUnwrap(workbench.bench?.focusedSlot)

        let result = spawner.openTerminal(cwd: mounted.value, named: .derived("claude · fixture"))

        guard case let .success(id) = result else {
            return XCTFail("a spawn naming the mounted workspace must succeed, got \(result)")
        }
        let bench = try XCTUnwrap(workbench.bench)
        XCTAssertEqual(bench.columns.count, 2, "one spawn appends one column on the right")
        XCTAssertEqual(
            bench.columns.last?.slots.flatMap(\.panes).map(\.id), [id],
            "the new pane is a column of its own at the right end")
        XCTAssertEqual(
            bench.focusedSlot, focused,
            "a spawn from outside takes neither the selection nor the keyboard")
    }

    /// The negative half: a request naming a workspace helm never actually mounted — the
    /// stub `activate` declines to switch, standing in for a folder that failed to open —
    /// must be refused rather than spawning into whatever IS mounted. A gate that is `true`
    /// unconditionally passes the test above for free; only this catches it.
    func testASpawnNamingAWorkspaceThatNeverBecomesMountedIsRefused() throws {
        let (spawner, terminals, _) = spawner(activate: { _ in })
        let before = terminals.sessions.count

        let result = spawner.openTerminal(cwd: elsewhere.value, named: .derived("claude · fixture"))

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
