import XCTest

@testable import Helm

/// Worktrees discovery and reading against real git repositories built in a temp home (#382):
/// what `WorktreeDiscovery` finds on disk, and what `WorktreeCLI` reads out of it. Real git
/// because the answers are git's own words — `upstream:track`, `--merged`, `commondir` — and a
/// fake would only repeat what the code already believes about them.
final class WorktreeGitTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var environment: [String: String] = [:]

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-worktree-git-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        environment = [
            "HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
        ]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: String..., in folder: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", folder.path] + arguments
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }

    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func commit(_ message: String, in folder: URL) throws {
        try message.write(
            to: folder.appendingPathComponent("\(message).txt"), atomically: true, encoding: .utf8)
        try git("add", ".", in: folder)
        try git("commit", "-q", "-m", message, in: folder)
    }

    /// `home/Projects/acme/app`, cloned from a bare origin so it has `origin/HEAD`, with a merged
    /// worktree, an unmerged one one commit ahead of its upstream and dirty, and a branch whose
    /// upstream was deleted.
    private func makeApp() throws -> URL {
        let seed = try folder("seed")
        try git("init", "-q", "-b", "main", in: seed)
        try commit("first", in: seed)
        let origin = root.appendingPathComponent("origin.git")
        try git("clone", "-q", "--bare", seed.path, origin.path, in: root)
        let app = try folder("home/Projects/acme")
            .appendingPathComponent("app")
        try git("clone", "-q", origin.path, app.path, in: root)

        try git("worktree", "add", "-q", "-b", "merged-one", ".worktrees/merged-one", in: app)
        try git("worktree", "add", "-q", "-b", "feature", ".worktrees/feature", in: app)
        let feature = app.appendingPathComponent(".worktrees/feature")
        try commit("pushed", in: feature)
        try git("push", "-q", "-u", "origin", "feature", in: feature)
        try commit("local", in: feature)
        try "edit".write(
            to: feature.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        try git("worktree", "add", "-q", "-b", "gone", ".worktrees/gone", in: app)
        let gone = app.appendingPathComponent(".worktrees/gone")
        try commit("gone-work", in: gone)
        try git("push", "-q", "-u", "origin", "gone", in: gone)
        try git("push", "-q", "origin", "--delete", "gone", in: gone)
        try git("fetch", "-q", "--prune", in: app)
        return app
    }

    // MARK: - Reading one repository

    func testReadsBranchStateUpstreamMergedAndDirtyFromGitItself() async throws {
        let app = try makeApp()

        let rows = try await WorktreeCLI(environment: environment)
            .worktrees(
                in: GitCommonDir(app.appendingPathComponent(".git").path),
                statusOfALoneCheckout: true)
        let byBranch = Dictionary(uniqueKeysWithValues: rows.map { ($0.record.branchName!, $0) })

        XCTAssertEqual(rows.first?.record.branchName, "main")
        XCTAssertEqual(rows.first?.isMain, true)
        XCTAssertEqual(byBranch["main"]?.status.tracking, .counts(ahead: 0, behind: 0))
        XCTAssertEqual(byBranch["merged-one"]?.mergedState, .merged)
        XCTAssertEqual(byBranch["merged-one"]?.status.isDirty, false)
        XCTAssertNil(byBranch["merged-one"]?.status.tracking, "no upstream")
        XCTAssertEqual(byBranch["feature"]?.mergedState, .unmerged)
        XCTAssertEqual(byBranch["feature"]?.status.tracking, .counts(ahead: 1, behind: 0))
        XCTAssertEqual(
            byBranch["feature"]?.status.isDirty, true, "an untracked file is work to lose")
        XCTAssertEqual(byBranch["gone"]?.status.tracking, .gone)
        let age = try XCTUnwrap(byBranch["feature"]?.status.lastCommitAt)
        XCTAssertLessThan(abs(age.timeIntervalSinceNow), 600)
    }

    /// Removal from the common directory — how the drawer names a repository — works.
    func testRemoveFromTheCommonDirectoryRemovesTheWorktree() async throws {
        let app = try makeApp()
        let merged = app.appendingPathComponent(".worktrees/merged-one").path

        try await WorktreeCLI(environment: environment)
            .remove(path: merged, in: GitCommonDir(app.appendingPathComponent(".git").path))

        XCTAssertFalse(FileManager.default.fileExists(atPath: merged))
        XCTAssertFalse(try git("worktree", "list", in: app).contains("merged-one"))
    }

    // MARK: - Discovery

    /// Projects are found by folder, down to a bounded depth, without descending into
    /// dependencies; Archon's worktrees lead back to their repository wherever it lives; a
    /// workspace inside a linked worktree names its repository. One repository reached three
    /// ways is one entry.
    func testDiscoveryFindsProjectsArchonWorktreesAndWorkspacesOnce() throws {
        let app = try makeApp()
        let solo = try folder("home/Projects/solo")
        try git("init", "-q", "-b", "main", in: solo)
        let vendored = try folder("home/Projects/web/node_modules/pkg")
        try git("init", "-q", in: vendored)
        let deep = try folder("home/Projects/a/b/c/d/e/deep")
        try git("init", "-q", in: deep)

        let lib = try folder("elsewhere/lib")
        try git("init", "-q", "-b", "main", in: lib)
        try commit("first", in: lib)
        let archonWorktree = home.appendingPathComponent(
            ".archon-test/workspaces/owner/lib/worktrees/archon/task-x")
        try FileManager.default.createDirectory(
            at: archonWorktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git("worktree", "add", "-q", "-b", "archon/task-x", archonWorktree.path, in: lib)
        let appArchon = home.appendingPathComponent(".archon/workspaces/o/app/worktrees/fix")
        try FileManager.default.createDirectory(
            at: appArchon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git("worktree", "add", "-q", "-b", "fix", appArchon.path, in: app)

        let found = WorktreeDiscovery(home: home).repositories(
            workspaces: [app.appendingPathComponent(".worktrees/feature").path])

        XCTAssertEqual(
            found,
            [
                .init(
                    commonDir: GitCommonDir(app.appendingPathComponent(".git").path),
                    isWorkspace: true),
                .init(
                    commonDir: GitCommonDir(lib.appendingPathComponent(".git").path),
                    isWorkspace: false),
                .init(
                    commonDir: GitCommonDir(solo.appendingPathComponent(".git").path),
                    isWorkspace: false),
            ],
            "node_modules and anything below the depth bound are not searched")
    }

    func testTheHomeCanBeMovedForAnIsolatedInstance() {
        XCTAssertEqual(
            WorktreeDiscovery(environment: ["HELM_WORKTREES_HOME": "/scratch/home"]).home.path,
            "/scratch/home")
        XCTAssertEqual(
            WorktreeDiscovery(environment: [:]).home.path, NSHomeDirectory())
    }
}
