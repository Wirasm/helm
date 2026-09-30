import XCTest

@testable import Helm

/// Worktrees reading against real git repositories built in a temp home (#382): what
/// `WorktreeCLI` reads out of them. Which repositories there are is benchd's `git/repositories`
/// now (M5c), tested beside it in `benchd/src/commands.rs`. Real git
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

        let rows = try await WorktreeCLI(host: host).worktrees(
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

    private var host: LocalBenchHost {
        LocalBenchHost(environment: environment, homeDirectory: home.path)
    }

    private var cli: WorktreeCLI { WorktreeCLI(host: host) }

    private func listed(_ app: URL) async throws -> [String: Worktree] {
        let rows = try await cli.worktrees(
            in: GitCommonDir(app.appendingPathComponent(".git").path), statusOfALoneCheckout: true)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.record.branchName ?? $0.id, $0) })
    }

    /// What a removal loses, in git's own counts: the untracked file and both commits on
    /// `feature` (one pushed, one not — neither is on origin/main), and nothing on `merged-one`.
    func testLossCountsUncommittedFilesAndCommitsTheDefaultBranchLacks() async throws {
        let app = try makeApp()
        let repo = GitCommonDir(app.appendingPathComponent(".git").path)
        let rows = try await listed(app)

        let feature = await cli.loss(of: try XCTUnwrap(rows["feature"]), in: repo)
        XCTAssertEqual(feature.uncommittedFiles, 1)
        XCTAssertEqual(feature.unmergedCommits, 2)
        XCTAssertEqual(feature.defaultBranch, "refs/remotes/origin/main")
        XCTAssertFalse(feature.deletesBranch)

        let merged = await cli.loss(of: try XCTUnwrap(rows["merged-one"]), in: repo)
        XCTAssertTrue(merged.losesNothing)
        XCTAssertTrue(merged.deletesBranch)
    }

    /// A merged, clean worktree goes with its branch; unmerged, dirty work goes only by force,
    /// and its branch stays, so no commit is lost with the worktree.
    func testRemovalTakesAMergedBranchAndKeepsAnUnmergedOne() async throws {
        let app = try makeApp()
        let repo = GitCommonDir(app.appendingPathComponent(".git").path)
        var rows = try await listed(app)

        for name in ["merged-one", "feature"] {
            let row = try XCTUnwrap(rows[name])
            let loss = await cli.loss(of: row, in: repo)
            try await cli.remove(row, in: repo, knowing: loss)
            XCTAssertFalse(FileManager.default.fileExists(atPath: row.record.path), name)
        }

        rows = try await listed(app)
        XCTAssertNil(rows["merged-one"])
        XCTAssertNil(rows["feature"])
        let branches = try git("branch", "--format=%(refname:short)", in: app)
        XCTAssertFalse(branches.contains("merged-one"), "merged, so it went too")
        XCTAssertTrue(branches.contains("feature"), "unmerged, so it stays")
    }

    /// A worktree whose folder is already gone is only git's record; `prune` clears it.
    func testAWorktreeWhoseFolderIsGoneIsPruned() async throws {
        let app = try makeApp()
        let repo = GitCommonDir(app.appendingPathComponent(".git").path)
        let gone = app.appendingPathComponent(".worktrees/gone")
        try FileManager.default.removeItem(at: gone)
        let before = try await listed(app)
        let row = try XCTUnwrap(before["gone"])
        XCTAssertFalse(row.exists)

        let loss = await cli.loss(of: row, in: repo)
        try await cli.remove(row, in: repo, knowing: loss)

        let after = try await listed(app)
        XCTAssertNil(after["gone"])
    }

    /// A new worktree checks out a local branch, tracks one only origin has, or starts a new
    /// branch from the default branch; inside `.worktrees` where the repository keeps them,
    /// beside the main checkout where it does not.
    func testCreateUsesTheBranchThatExistsAndTheRepositorysPlace() async throws {
        let app = try makeApp()
        let repo = GitCommonDir(app.appendingPathComponent(".git").path)
        try git("push", "-q", "origin", "main:refs/heads/remote-only", in: app)
        try git("fetch", "-q", in: app)
        try git("branch", "-q", "local-only", in: app)

        let fresh = try await cli.create(branch: "feat/fresh", in: repo, main: app.path)
        let remote = try await cli.create(branch: "remote-only", in: repo, main: app.path)
        let local = try await cli.create(branch: "local-only", in: repo, main: app.path)

        XCTAssertEqual(fresh, app.appendingPathComponent(".worktrees/feat-fresh").path)
        XCTAssertEqual(
            try git(
                "rev-parse", "--abbrev-ref", "HEAD@{upstream}", in: URL(fileURLWithPath: remote)
            )
            .trimmingCharacters(in: .whitespacesAndNewlines),
            "origin/remote-only")
        XCTAssertEqual(
            try git("rev-parse", "HEAD", in: URL(fileURLWithPath: fresh)),
            try git("rev-parse", "origin/main", in: app), "a new branch starts at the default")
        XCTAssertEqual(
            try git("branch", "--show-current", in: URL(fileURLWithPath: local))
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "local-only")

        let lib = try folder("home/Projects/acme/lib")
        try git("init", "-q", "-b", "main", in: lib)
        try commit("first", in: lib)
        let sibling = try await cli.create(
            branch: "fix/a", in: GitCommonDir(lib.appendingPathComponent(".git").path),
            main: lib.path)
        XCTAssertEqual(
            sibling, lib.deletingLastPathComponent().appendingPathComponent("lib-fix-a").path)
    }

    func testCreateRefusesABranchNameGitWouldNot() async throws {
        let app = try makeApp()
        do {
            _ = try await cli.create(
                branch: "bad..name", in: GitCommonDir(app.appendingPathComponent(".git").path),
                main: app.path)
            XCTFail("expected a refusal")
        } catch let error as WorktreeCLIError {
            XCTAssertTrue(error.command.contains("check-ref-format"), error.command)
        }
    }
}
