import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The Worktrees drawer's delete rules through helm's whole path over the wire (M5c, #459):
/// `WorktreesModel` → `WorktreeCLI` → `BenchdHost` → a benchd stand-in that runs real git in a temp
/// repository by benchd's rules (`FakeBenchd.answersCommands`). `MachineOverTCPTests` is the same
/// flow against a real benchd, run by the evidence harness.
@MainActor
final class WorktreeDeleteOverTheWireTests: XCTestCase {
    private var root: URL!
    private var server: FakeBenchd?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Physically, as git prints it (`/private/var/…`): `resolvingSymlinksInPath` drops
        // `/private`, and the rows would not match.
        let physical = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical))
    }

    override func tearDown() {
        server?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func benchd() throws -> FakeBenchd {
        let server = try FakeBenchd(
            document: DocumentAt(seq: 1, document: BenchDocument(workspaces: [], active: nil)),
            tcp: true)
        self.server = server
        return server
    }

    // MARK: - The Worktrees drawer's delete rules, over the wire

    private var gitEnvironment: [String: String] {
        [
            "HOME": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
        ]
    }

    @discardableResult
    private func git(_ arguments: String..., in folder: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", folder.path] + arguments
        process.environment = gitEnvironment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ name: String, in folder: URL) throws {
        try name.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// `app`, cloned from a bare origin so it has a default branch, with a worktree `merged-one`
    /// at main's tip and a worktree `feature` one commit ahead of it.
    private func makeApp() throws -> URL {
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main", in: seed)
        try write("first.txt", in: seed)
        try git("add", ".", in: seed)
        try git("commit", "-q", "-m", "first", in: seed)
        let origin = root.appendingPathComponent("origin.git")
        try git("clone", "-q", "--bare", seed.path, origin.path, in: root)
        let app = root.appendingPathComponent("app")
        try git("clone", "-q", origin.path, app.path, in: root)
        try git("worktree", "add", "-q", "-b", "merged-one", ".worktrees/merged-one", in: app)
        try git("worktree", "add", "-q", "-b", "feature", ".worktrees/feature", in: app)
        let feature = app.appendingPathComponent(".worktrees/feature")
        try write("feature.txt", in: feature)
        try git("add", ".", in: feature)
        try git("commit", "-q", "-m", "unmerged", in: feature)
        return app
    }

    private func drawer(for app: URL) throws -> WorktreesModel {
        let server = try benchd()
        server.answersCommands(
            with: LocalBenchHost(environment: gitEnvironment, homeDirectory: root.path))
        let host = BenchdHost(endpoint: server.endpoint)
        let common = app.appendingPathComponent(".git").path
        return WorktreesModel(
            worktreeClient: WorktreeCLI(host: host),
            discover: { _ in [BenchGitRepository(commonDir: common, isWorkspace: true)] })
    }

    private func row(_ model: WorktreesModel, _ path: URL) throws -> Worktree {
        try XCTUnwrap(model.repos.flatMap(\.worktrees).first { $0.id == path.path }, path.path)
    }

    /// Through `command/run` and `path/exists`: the confirmation names the uncommitted file and
    /// the commit main does not have; new work written while it is open asks again naming both
    /// files; and the confirmed delete keeps the unmerged branch.
    func testADeleteOverTheWireNamesTheLossAsksAgainAndKeepsAnUnmergedBranch() async throws {
        let app = try makeApp()
        let feature = app.appendingPathComponent(".worktrees/feature")
        let model = try drawer(for: app)
        await model.refresh(workspaces: [])
        XCTAssertNil(model.refreshFailures.first?.value)
        try write("untracked.txt", in: feature)

        await model.requestDelete(of: try row(model, feature))
        guard case let .delete(_, loss) = model.confirmation else {
            return XCTFail("no confirmation: \(String(describing: model.confirmation))")
        }
        XCTAssertEqual(loss.uncommittedFiles, 1)
        XCTAssertEqual(loss.unmergedCommits, 1)
        XCTAssertFalse(loss.deletesBranch)

        try write("more.txt", in: feature)
        await model.confirm()
        guard case let .delete(_, again) = model.confirmation else {
            return XCTFail("new work must be asked about again")
        }
        XCTAssertEqual(again.uncommittedFiles, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: feature.path), "nothing removed yet")

        await model.confirm()
        XCTAssertNil(model.actionFailures[feature.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: feature.path))
        XCTAssertEqual(
            try git("branch", "--list", "feature", in: app)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "feature", "an unmerged branch is never deleted")
    }

    /// A worktree whose branch main reaches loses nothing, and its branch goes with it.
    func testAMergedWorktreeOverTheWireGoesWithItsBranch() async throws {
        let app = try makeApp()
        let merged = app.appendingPathComponent(".worktrees/merged-one")
        let model = try drawer(for: app)
        await model.refresh(workspaces: [])

        await model.requestDelete(of: try row(model, merged))
        guard case let .delete(_, loss) = model.confirmation else {
            return XCTFail("no confirmation")
        }
        XCTAssertTrue(loss.losesNothing)
        await model.confirm()

        XCTAssertFalse(FileManager.default.fileExists(atPath: merged.path))
        XCTAssertEqual(try git("branch", "--list", "merged-one", in: app), "")
    }

    /// The stand-in holds benchd's rule too: a worktree under a folder that may not be searched is
    /// "could not look", which fails the listing, never "missing", which would be pruned.
    func testAWorktreeThatCannotBeLookedAtFailsTheListingOverTheWire() async throws {
        let app = try makeApp()
        let worktrees = app.appendingPathComponent(".worktrees")
        let model = try drawer(for: app)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: worktrees.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: worktrees.path)
        }
        await model.refresh(workspaces: [])
        XCTAssertTrue(model.repos.isEmpty, "no row read as missing")
        XCTAssertEqual(model.refreshFailures.values.first?.contains("cannot tell"), true)
    }

    /// benchd unable to say which worktrees exist fails the repository's listing: a row read as
    /// missing would be pruned, so "could not look" never becomes "gone". Discovery failing says
    /// so on the drawer rather than showing an empty list.
    func testCouldNotLookIsAFailureNotAMissingWorktreeOrAnEmptyDrawer() async throws {
        let app = try makeApp()
        let model = try drawer(for: app)
        let server = try XCTUnwrap(server)
        let answers = server.answer
        server.answer = { request in
            guard request["verb"] as? String == "path/exists" else { return answers(request) }
            return [
                "id": request["id"] ?? "", "status": "refused", "reason": "cannot tell: denied",
            ]
        }
        await model.refresh(workspaces: [])
        XCTAssertTrue(model.repos.isEmpty, "no rows invented")
        XCTAssertEqual(model.refreshFailures.values.first?.contains("cannot tell"), true)

        let lost = WorktreesModel(
            worktreeClient: WorktreeCLI(host: BenchdHost(endpoint: nil)),
            discover: { _ in throw BenchHostFailure(reason: "benchd is not answering") })
        await lost.refresh(workspaces: [])
        XCTAssertEqual(lost.discoveryFailure, "benchd is not answering")
    }
}
