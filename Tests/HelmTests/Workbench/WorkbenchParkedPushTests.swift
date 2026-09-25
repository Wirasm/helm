import XCTest

@testable import Helm

/// A push from a workspace the operator is not looking at (#349).
///
/// A push comes from terminal output, and a parked workspace's terminals keep running, so an agent
/// in one can push at any time. Before #349 `WorkbenchModel` dropped that push because it only
/// knows the mounted bench, and `push.sh` still exited 0. The canvas now lands on the parked
/// workspace's stored bench and is there when the operator switches in.
///
/// Driven through the real command and a real `WorkspaceModel`, switched the way `RootView` does it
/// (save, select, activate from `contexts`), because the defect was the hop between the two models
/// and neither suite on its own could see it.
@MainActor
final class WorkbenchParkedPushTests: XCTestCase {
    private let parkedPath = WorkspacePath("/tmp/helm-parked-push")
    private let mountedPath = WorkspacePath("/tmp/helm-parked-push-mounted")
    private let artifact = URL(fileURLWithPath: "/tmp/helm-parked-push/report.md")

    private struct Rig {
        let workbench: WorkbenchModel
        let workspaces: WorkspaceModel
        let manager: TerminalManager
        let defaults: UserDefaults
    }

    /// `parkedPath` mounted, then parked by switching to `mountedPath` — `RootView`'s wiring and
    /// its switch, with nothing else.
    private func parkedRig() throws -> Rig {
        let manager = TerminalManager()
        let workbench = WorkbenchModel(terminals: manager)
        let defaults = try isolatedDefaults("parked-push")
        let workspaces = WorkspaceModel(defaults: defaults)
        workbench.parked = workspaces
        workspaces.open(Workspace(path: parkedPath.value))
        workbench.activate(workspacePath: parkedPath)
        let rig = Rig(
            workbench: workbench, workspaces: workspaces, manager: manager, defaults: defaults)
        switchTo(mountedPath, in: rig)
        return rig
    }

    /// `RootView.switchWorkspace` → `activateSelectedWorkspace`, without asking: persist the bench
    /// being left, select, mount whatever is stored for the one being entered.
    private func switchTo(_ path: WorkspacePath, in rig: Rig) {
        rig.workspaces.saveContext(terminalManager: rig.manager, workbench: rig.workbench)
        rig.workspaces.open(Workspace(path: path.value))
        rig.workbench.activate(
            workspacePath: path, restoring: rig.workspaces.contexts[path.value]?.workbench)
    }

    private func push(for path: WorkspacePath) async throws {
        HelmCommand.pushCanvasFile(
            CanvasPushRequest(
                artifact: artifact, workspacePath: path, origin: CanvasOrigin(terminal: UUID()))
        ).post()
        try await Task.sleep(for: .milliseconds(100))
    }

    private func stored(_ path: WorkspacePath, in rig: Rig) throws -> Workbench {
        try XCTUnwrap(rig.workspaces.contexts[path.value]?.workbench)
    }

    // MARK: -

    /// The bug: the push has to be on the parked bench, and still there after switching in.
    func testAPushFromAParkedWorkspaceIsOnItsBenchWhenTheOperatorSwitchesIn() async throws {
        let rig = try parkedRig()

        try await push(for: parkedPath)

        XCTAssertEqual(
            try stored(parkedPath, in: rig).canvasPanes.map(\.content),
            [.canvas(.file(artifact))],
            "a push from a parked workspace has to land on that workspace's stored bench")

        switchTo(parkedPath, in: rig)
        XCTAssertEqual(
            rig.workbench.bench?.canvasPanes.map(\.content), [.canvas(.file(artifact))],
            "…and be on screen once the operator switches to it")
    }

    /// Offered, not inserted: what the parked bench was showing and where its focus was are both
    /// unchanged, so switching in finds the operator's arrangement rather than the agent's.
    func testAParkedPushDoesNotChangeWhatThatBenchShowsOrWhereItsFocusIs() async throws {
        let rig = try parkedRig()
        let before = try stored(parkedPath, in: rig)

        try await push(for: parkedPath)

        let after = try stored(parkedPath, in: rig)
        XCTAssertEqual(after.focusedSlot, before.focusedSlot)
        XCTAssertEqual(after.focusedPane, before.focusedPane)
        XCTAssertTrue(
            before.visiblePaneIDs.isSubset(of: after.visiblePaneIDs),
            "every pane the operator could see before the push is still showing")
    }

    /// The existing guard's reason, from the other side: the bench on screen is not the parked
    /// workspace's and must not receive its push. Passes before and after #349, and must — a fix
    /// that landed the push on whatever is mounted would satisfy the first test and fail this.
    func testTheMountedBenchIsNotTouchedByAParkedPush() async throws {
        let rig = try parkedRig()
        let mountedBefore = rig.workbench.bench

        try await push(for: parkedPath)

        XCTAssertEqual(rig.workbench.bench, mountedBefore)
        XCTAssertEqual(rig.workbench.bench?.canvasPanes.count, 0)
    }

    /// An agent re-pushing the file it just rewrote is the common case, and it must not stack a
    /// second tab on the parked bench.
    func testARePushFromAParkedWorkspaceKeepsOnePane() async throws {
        let rig = try parkedRig()

        try await push(for: parkedPath)
        try await push(for: parkedPath)

        XCTAssertEqual(try stored(parkedPath, in: rig).canvasPanes.count, 1)
    }

    /// The push has to reach `UserDefaults`, not only the in-memory context: a relaunch before the
    /// operator ever switches in reads the bench from there.
    func testAParkedPushIsPersisted() async throws {
        let rig = try parkedRig()

        try await push(for: parkedPath)

        let reloaded = WorkspaceModel(defaults: rig.defaults)
        XCTAssertEqual(
            reloaded.contexts[parkedPath.value]?.workbench?.canvasPanes.map(\.content),
            [.canvas(.file(artifact))])
    }
}
