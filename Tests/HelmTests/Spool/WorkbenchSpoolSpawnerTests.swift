import HelmWire
import XCTest

@testable import Helm

/// `WorkspacePathSpoolAgreementTests` pins that `WorkspacePath` and `SpoolPolicy.accept`
/// normalize a `cwd` identically — the two SIDES of the boundary agreeing on a string. What
/// it does not reach is `WorkbenchSpoolSpawner.openTerminal`'s own gate: having agreed on the
/// string, does a spawn actually land only when it names the workspace helm has mounted.
///
/// `activate` here is a stub rather than real `RootView` wiring — this is
/// `WorkbenchSpoolSpawner`'s own decision under test, against a toy benchd (`ToyBench`), not
/// whether activation succeeds end-to-end.
@MainActor
final class WorkbenchSpoolSpawnerTests: XCTestCase {
    private let mounted = WorkspacePath("/tmp/helm-spool-spawner-mounted")
    private let elsewhere = WorkspacePath("/tmp/helm-spool-spawner-elsewhere")

    private func spawner(
        activate: @escaping @MainActor (Workspace) -> Void = { _ in }
    ) throws -> (WorkbenchSpoolSpawner, TerminalManager, ToyRig) {
        let rig = try toyRig(mounted.value)
        let spawner = WorkbenchSpoolSpawner(
            workbench: rig.model, terminals: rig.terminals, activate: activate)
        return (spawner, rig.terminals, rig)
    }

    /// The matching case: a request naming the workspace already on screen never even needs
    /// `activate` to do anything, and a session comes back.
    func testASpawnNamingTheMountedWorkspaceSucceeds() throws {
        let (spawner, terminals, _) = try spawner()
        let before = terminals.sessions(for: mounted).count

        let result = spawner.openTerminal(cwd: mounted.value, named: .derived("claude · fixture"))

        guard case let .success(id) = result else {
            return XCTFail("a spawn naming the mounted workspace must succeed, got \(result)")
        }
        XCTAssertEqual(terminals.sessions(for: mounted).count, before + 1)
        XCTAssertTrue(terminals.sessions(for: mounted).contains { $0.id == id })
    }

    /// **The boundary the reported defect actually crossed (#177).** A spawn is an agent's
    /// `pane/open` of a terminal naming the request's workspace — so benchd's rule gives it a
    /// column of its own and leaves the keyboard alone. Sent as the operator, it would stack as a
    /// tab on whatever had focus and take the keyboard, which is the defect the operator
    /// reported. This pins the adapter's own choice; where the pane lands is `bench-doc`'s.
    func testASpawnIsAnAgentsOpenOfATerminalInTheRequestsWorkspace() throws {
        let (spawner, _, rig) = try spawner()

        let result = spawner.openTerminal(cwd: mounted.value, named: .derived("claude · fixture"))

        guard case .success = result else {
            return XCTFail("a spawn naming the mounted workspace must succeed, got \(result)")
        }
        let open = try XCTUnwrap(rig.server.verbs.first { $0["verb"] as? String == "pane/open" })
        XCTAssertEqual((open["by"] as? [String: Any])?["kind"] as? String, "agent")
        XCTAssertNil(open["asked"], "a spawn does not claim the operator asked")
        let args = try XCTUnwrap(open["args"] as? [String: Any])
        XCTAssertEqual(args["workspace"] as? String, mounted.value)
        XCTAssertEqual((args["surface"] as? [String: Any])?["kind"] as? String, "terminal")
    }

    /// **A spawn into a workspace that is not on screen puts it on screen** (the plan's M5b
    /// exception). A terminal's pty starts only once its pane is drawn, and helm draws only the
    /// workspace on screen — opened in the background, the spawn would paste its launch line into
    /// a shell that never started and fail at the spool's deadline.
    func testASpawnIntoAnotherWorkspaceOpensItOnScreenAsTheOperatorAsked() throws {
        let rig = try toyRig(mounted.value)
        let spawner = WorkbenchSpoolSpawner(
            workbench: rig.model, terminals: rig.terminals,
            activate: rig.model.openWorkspaceForSpawn)

        let result = spawner.openTerminal(
            cwd: elsewhere.value, named: .derived("claude · fixture"))

        guard case let .success(id) = result else {
            return XCTFail("a spawn naming another workspace must succeed, got \(result)")
        }
        let open = try XCTUnwrap(
            rig.server.verbs.first { $0["verb"] as? String == "workspace/open" })
        XCTAssertEqual((open["by"] as? [String: Any])?["kind"] as? String, "agent")
        XCTAssertEqual(open["asked"] as? Bool, true)
        XCTAssertEqual(rig.model.workspacePath, elsewhere, "the spawn's workspace is on screen")
        XCTAssertTrue(
            rig.terminals.sessions(for: elsewhere).contains { $0.id == id },
            "and the spawned pane has a session there, to be drawn")
    }

    /// The negative half: a request naming a workspace helm never actually mounted — the
    /// stub `activate` declines to switch, standing in for a folder that failed to open —
    /// must be refused rather than spawning into whatever IS mounted. A gate that is `true`
    /// unconditionally passes the test above for free; only this catches it.
    func testASpawnNamingAWorkspaceThatNeverBecomesMountedIsRefused() throws {
        let (spawner, terminals, _) = try spawner(activate: { _ in })
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
