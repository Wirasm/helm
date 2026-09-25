import XCTest

@testable import Helm

/// The tab's branch label (#379). It used to be asked once, persisted with a
/// `branchResolved` flag and never asked again, so a tab showed the branch its folder had the
/// first time it was opened, forever.
@MainActor
final class WorkspaceBranchTests: XCTestCase {
    private let workspace = Workspace(path: "/tmp/helm-branch-tests")

    /// What git answers, changed by the test between asks.
    private actor Git {
        var branch: String?
        func set(_ value: String?) { branch = value }
    }

    func testTheLabelFollowsTheBranchTheFolderIsOnNow() async throws {
        let git = Git()
        let model = WorkspaceModel(
            defaults: try isolatedDefaults("branch-follows"), readBranch: { _ in await git.branch })
        model.open(workspace)

        await git.set("main")
        await model.refreshBranch(for: workspace)
        XCTAssertEqual(model.branches[workspace.path], "main")

        await git.set("feat/x")
        await model.refreshBranch(for: workspace)
        XCTAssertEqual(
            model.branches[workspace.path], "feat/x", "the second ask is answered, not skipped")

        await git.set(nil)
        await model.refreshBranch(for: workspace)
        XCTAssertNil(
            model.branches[workspace.path],
            "no branch now (detached, or no longer a repository) clears the old label")
    }

    /// A relaunch starts with no label and asks, even over a blob an older build wrote with
    /// `branchResolved: true`, the flag that used to stop every later ask.
    func testARelaunchRemembersNoBranch() async throws {
        let defaults = try isolatedDefaults("branch-relaunch")
        defaults.set(
            #"{"\#(workspace.path.value)":{"branch":"old","branchResolved":true}}"#,
            forKey: WorkspaceContextStore.key)
        let first = WorkspaceModel(defaults: defaults, readBranch: { _ in "main" })
        first.open(workspace)
        await first.refreshBranch(for: workspace)

        let relaunched = WorkspaceModel(defaults: defaults, readBranch: { _ in "today" })
        XCTAssertNil(relaunched.branches[workspace.path], "nothing about the branch persisted")
        await relaunched.refreshBranch(for: workspace)
        XCTAssertEqual(relaunched.branches[workspace.path], "today")
    }

    /// The default reader against a real repository: the branch it is on, and a new one after a
    /// checkout. A folder that is not a repository has none.
    func testGitIsAskedForTheCurrentBranch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = WorkspacePath(dir.path)

        let notARepository = await WorkspaceModel.currentBranch(in: path)
        XCTAssertNil(notARepository)

        try git(["init", "-q", "-b", "main", dir.path])
        let first = await WorkspaceModel.currentBranch(in: path)
        XCTAssertEqual(first, "main")

        try git(["-C", dir.path, "checkout", "-q", "-b", "feat/x"])
        let second = await WorkspaceModel.currentBranch(in: path)
        XCTAssertEqual(second, "feat/x")
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}
