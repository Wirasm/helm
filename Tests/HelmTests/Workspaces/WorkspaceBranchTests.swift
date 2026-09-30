import HelmWire
import XCTest

@testable import Helm

/// The tab's branch label (#379). It used to be asked once, persisted with a
/// `branchResolved` flag and never asked again, so a tab showed the branch its folder had the
/// first time it was opened, forever.
@MainActor
final class WorkspaceBranchTests: XCTestCase {
    private let workspace = Workspace(path: "/tmp/helm-branch-tests")

    /// benchd's document naming `workspaces`, the first on screen.
    private func document(_ workspaces: [Workspace]) -> BenchDocument {
        BenchDocument(
            workspaces: workspaces.map {
                .init(path: $0.path.value, bench: ToyBench.bench([ToyBench.terminal()]))
            }, active: workspaces.first?.path.value)
    }

    /// What git answers, changed by the test between asks.
    private actor Git {
        var branch: String?
        func set(_ value: String?) { branch = value }
    }

    func testTheLabelFollowsTheBranchTheFolderIsOnNow() async throws {
        let git = Git()
        let model = WorkspaceModel(readBranch: { _ in await git.branch })
        model.follow(document([workspace]))

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

    /// A read that got no answer — benchd not reached, git timing out — keeps the label: it says
    /// nothing about the branch. Only git answering "no branch" clears it.
    func testAFailedReadKeepsTheLabel() async throws {
        let git = Git()
        let failing = LockedFlag()
        let model = WorkspaceModel(readBranch: { _ in
            if failing.value { throw BenchHostFailure(reason: "benchd is not answering") }
            return await git.branch
        })
        model.follow(document([workspace]))
        await git.set("main")
        await model.refreshBranch(for: workspace)

        failing.set(true)
        await model.refreshBranch(for: workspace)
        XCTAssertEqual(model.branches[workspace.path], "main")
    }

    /// A workspace closed while git was still answering does not get its label back.
    func testAnAnswerForAClosedWorkspaceIsDropped() async throws {
        let git = SlowGit()
        let model = WorkspaceModel(readBranch: { _ in await git.ask() })
        model.follow(document([workspace]))

        let refresh = Task { await model.refreshBranch(for: workspace) }
        await git.untilAsked()
        model.follow(document([]))
        await git.answer("main")
        await refresh.value

        XCTAssertNil(model.branches[workspace.path])
    }

    /// Holds git's answer until the test releases it.
    private actor SlowGit {
        private var pending: CheckedContinuation<String?, Never>?
        private var asked: CheckedContinuation<Void, Never>?

        func ask() async -> String? {
            await withCheckedContinuation { continuation in
                pending = continuation
                asked?.resume()
                asked = nil
            }
        }

        func untilAsked() async {
            guard pending == nil else { return }
            await withCheckedContinuation { asked = $0 }
        }

        func answer(_ branch: String?) {
            pending?.resume(returning: branch)
            pending = nil
        }
    }

    /// The default reader against a real repository: the branch it is on, and a new one after a
    /// checkout. A folder that is not a repository has none.
    func testGitIsAskedForTheCurrentBranch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = WorkspacePath(dir.path)
        let host = LocalBenchHost(
            environment: ProcessInfo.processInfo.environment, homeDirectory: dir.path)

        let notARepository = try await WorkspaceModel.currentBranch(in: path, host: host)
        XCTAssertNil(notARepository)

        try git(["init", "-q", "-b", "main", dir.path])
        let first = try await WorkspaceModel.currentBranch(in: path, host: host)
        XCTAssertEqual(first, "main")

        try git(["-C", dir.path, "checkout", "-q", "-b", "feat/x"])
        let second = try await WorkspaceModel.currentBranch(in: path, host: host)
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

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ newValue: Bool) { lock.withLock { stored = newValue } }
}
