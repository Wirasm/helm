import Foundation
import HelmWire
import XCTest

@testable import Helm

/// `BenchdHost` (M5c, #459): helm's git and archon, asked of benchd. The wire against the shared
/// fixture, every way an answer can fail staying a failure, waiting that holds no cooperative
/// thread, and the Worktrees drawer's delete rules over the wire against real git.
@MainActor
final class BenchHostTests: XCTestCase {
    private var root: URL!
    private var server: FakeBenchd?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-host-\(UUID().uuidString)")
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

    private func answering(_ data: [String: Any]) throws -> BenchdHost {
        let server = try benchd()
        nonisolated(unsafe) let data = data
        server.answer = { ["id": $0["id"] ?? "", "status": "ok", "data": data] }
        return BenchdHost(endpoint: server.endpoint)
    }

    // MARK: - The wire

    private static let app = "/Users/op/Projects/app"

    /// `daemon/fixtures/command-verbs.json`, which the daemon gate holds to `bench_wire::commands`.
    private func samples() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/fixtures/command-verbs.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    /// `command-verbs.json` pins the three verbs: each request helm sends encodes to the fixture's.
    func testTheCommandRequestsAreSpelledAsTheDaemonSpellsThem() throws {
        let samples = try samples()
        func plain(_ data: Data) throws -> NSObject {
            try JSONSerialization.jsonObject(with: data) as! NSObject
        }
        func sample(_ key: String) throws -> NSObject {
            try plain(JSONSerialization.data(withJSONObject: XCTUnwrap(samples[key])))
        }
        let app = Self.app
        let requests: [(String, any Encodable)] = [
            (
                "git",
                BenchCommandRunRequest(
                    id: "helm-cmd-1",
                    command: .git(args: ["-C", "\(app)/.git", "worktree", "list", "--porcelain"]),
                    timeoutMs: 20000)
            ),
            (
                "git_in",
                BenchCommandRunRequest(
                    id: "helm-cmd-2", command: .git(args: ["branch", "--show-current"], cwd: app),
                    timeoutMs: 10000)
            ),
            (
                "archon",
                BenchCommandRunRequest(
                    id: "helm-cmd-3",
                    command: .archon(args: ["workflow", "runs", "--json"], cwd: app),
                    timeoutMs: 20000)
            ),
            (
                "archon_complete",
                BenchCommandRunRequest(
                    id: "helm-cmd-4",
                    command: .archon(
                        args: ["complete", "archon/task-x"], cwd: app, home: "/Users/op/.archon"),
                    timeoutMs: 120_000)
            ),
            (
                "exists",
                BenchPathExistsRequest(id: "helm-cmd-5", paths: [app, "\(app)/.worktrees/gone"])
            ),
            (
                "repositories",
                BenchGitRepositoriesRequest(
                    id: "helm-cmd-6", workspaces: ["\(app)/.worktrees/feature"])
            ),
        ]
        for (key, request) in requests {
            XCTAssertEqual(try plain(JSONEncoder().encode(request)), try sample(key), key)
        }
    }

    /// Each answer in `command-verbs.json` decodes to what the daemon's side wrote.
    func testTheCommandAnswersDecodeAsTheDaemonWritesThem() throws {
        let samples = try samples()
        let app = Self.app
        func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
            try JSONDecoder().decode(
                type, from: JSONSerialization.data(withJSONObject: XCTUnwrap(samples[key])))
        }
        XCTAssertEqual(
            try decode([BenchCommandRun].self, "run_answers"),
            [
                .exited(status: 0, stdout: Data("main\n".utf8), stderr: Data()),
                .exited(
                    status: 128, stdout: Data(), stderr: Data("fatal: not a git repository\n".utf8)),
                .timedOut,
            ])
        XCTAssertEqual(try decode(BenchPathExists.self, "existing").existing, [app])
        XCTAssertEqual(
            try decode(BenchGitRepositories.self, "found").repositories,
            [
                .init(commonDir: "\(app)/.git", isWorkspace: true),
                .init(commonDir: "/Users/op/Projects/lib/.git", isWorkspace: false),
            ])
    }

    // MARK: - Answers and failures

    func testAnExitIsAResultWithItsStatusAndBothStreams() async throws {
        let host = try answering([
            "kind": "exited", "status": 1, "stdout": Data("out".utf8).base64EncodedString(),
            "stderr": Data("err".utf8).base64EncodedString(),
        ])
        let result = try await host.run(.git(args: ["status"]), timeout: .seconds(5))
        XCTAssertEqual(result.status, 1, "a nonzero exit is an answer, not a failure")
        XCTAssertEqual(result.stdout, Data("out".utf8))
        XCTAssertEqual(result.stderr, Data("err".utf8))
        let sent = try XCTUnwrap(server?.requests.last)
        XCTAssertEqual(sent["verb"] as? String, "command/run")
        XCTAssertEqual((sent["args"] as? [String: Any])?["timeout_ms"] as? Int, 5000)
    }

    func testTimedOutIsTheTimeoutFailure() async throws {
        let host = try answering(["kind": "timed_out"])
        do {
            _ = try await host.run(.git(args: ["status"]), timeout: .seconds(1))
            XCTFail("expected a timeout")
        } catch let failure as Subprocess.Failure {
            XCTAssertEqual(failure, .timedOut)
        }
    }

    /// benchd refusing, and benchd not being there, are failures that say why — never an empty
    /// success, never "not there".
    func testARefusalAndAnAbsentBenchdAreFailuresNamingWhy() async throws {
        let server = try benchd()
        server.answer = {
            [
                "id": $0["id"] ?? "", "status": "refused",
                "reason": "archon is not installed on benchd's machine: looked in /h/.bun/bin",
            ]
        }
        let host = BenchdHost(endpoint: server.endpoint)
        do {
            _ = try await host.run(
                .archon(args: ["workflow", "runs"], cwd: "/w"), timeout: .seconds(5))
            XCTFail("expected a refusal")
        } catch let failure as Subprocess.Failure {
            XCTAssertEqual(
                failure,
                .launchFailed("archon is not installed on benchd's machine: looked in /h/.bun/bin"))
        }
        do {
            _ = try await host.existing(["/w"])
            XCTFail("expected a refusal")
        } catch let failure as BenchHostFailure {
            XCTAssertTrue(failure.reason.contains("not installed"), failure.reason)
        }

        server.stop()
        do {
            _ = try await host.existing(["/w"])
            XCTFail("benchd is gone")
        } catch let failure as BenchHostFailure {
            XCTAssertTrue(failure.reason.contains("benchd"), failure.reason)
        }
        do {
            _ = try await BenchdHost(endpoint: nil).repositories(workspaces: [])
            XCTFail("there is no benchd to ask")
        } catch is BenchHostFailure {}
    }

    /// Cancelling the task stops the wait at once: the drawer hidden mid-refresh.
    func testCancellingStopsWaitingForAnAnswer() async throws {
        let server = try benchd()
        let gate = DispatchSemaphore(value: 0)
        server.answer = { request in
            _ = gate.wait(timeout: .now() + 10)
            return ["id": request["id"] ?? "", "status": "ok", "data": ["kind": "timed_out"]]
        }
        defer { for _ in 0..<4 { gate.signal() } }
        let host = BenchdHost(endpoint: server.endpoint)
        let call = Task { try await host.run(.git(args: ["status"]), timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    /// Waiting on benchd must not hold a thread of Swift's cooperative pool (#377's rule for
    /// `Subprocess`): the drawer reads six repositories at once, each answer can take a command's
    /// whole deadline, and the pool has one thread per core.
    ///
    /// Synchronous on purpose: the test body must not need the pool it is checking. benchd's
    /// answers wait on a gate the test opens itself.
    nonisolated func testWaitingOnBenchdHoldsNoThreadOfTheCooperativePool() throws {
        let server = try FakeBenchd(
            document: DocumentAt(seq: 1, document: BenchDocument(workspaces: [], active: nil)),
            tcp: true)
        defer { server.stop() }
        let gate = DispatchSemaphore(value: 0)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let waiting = LockedCount()
        server.answer = { request in
            waiting.increment()
            _ = gate.wait(timeout: .now() + 30)
            return ["id": request["id"] ?? "", "status": "ok", "data": ["kind": "timed_out"]]
        }
        defer { for _ in 0..<(cores * 2) { gate.signal() } }
        let host = BenchdHost(endpoint: server.endpoint)
        let finished = expectation(description: "every call returned")
        finished.expectedFulfillmentCount = cores * 2
        for _ in 0..<(cores * 2) {
            Task.detached {
                _ = try? await host.run(.git(args: ["status"]), timeout: .seconds(30))
                finished.fulfill()
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while waiting.value < cores, Date() < deadline { usleep(20_000) }
        XCTAssertGreaterThanOrEqual(waiting.value, cores, "a pool's width of asks are waiting")

        let probed = expectation(description: "the probe ran")
        Task.detached { probed.fulfill() }
        wait(for: [probed], timeout: 10)

        for _ in 0..<(cores * 2) { gate.signal() }
        wait(for: [finished], timeout: 30)
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

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}
