import Foundation
import HelmWire
import XCTest

@testable import Helm

/// `BenchdHost` (M5c, #459): helm's git and archon, asked of benchd. The wire against the shared
/// fixture, every way an answer can fail staying a failure, and waiting that holds no cooperative
/// thread. The Worktrees drawer's delete rules over the wire are `WorktreeDeleteOverTheWireTests`.
@MainActor
final class BenchHostTests: XCTestCase {
    private var server: FakeBenchd?

    override func tearDown() {
        server?.stop()
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
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

/// Two edges of `BenchdHost` on the wire: an answer lost after the request went out, and many
/// paths asked in slices under the request cap.
final class BenchHostWireEdgeTests: XCTestCase {
    /// benchd took the request and the connection closed with no answer: the words say it may have
    /// run, never that it could not start.
    func testALostAnswerSaysTheCommandMayHaveRun() async throws {
        let listener = try TCPOneShot()
        defer { listener.close() }
        let host = BenchdHost(endpoint: .tcp(host: "127.0.0.1", port: listener.port))
        do {
            _ = try await host.run(.git(args: ["worktree", "add", "/x"]), timeout: .seconds(5))
            XCTFail("no answer came")
        } catch let failure as Subprocess.Failure {
            guard case let .launchFailed(why) = failure else { return XCTFail("\(failure)") }
            XCTAssertTrue(why.contains("may have run"), why)
        }
    }

    func testManyPathsAreAskedInSlicesUnderTheRequestCap() async throws {
        let server = try FakeBenchd(
            document: DocumentAt(seq: 1, document: BenchDocument(workspaces: [], active: nil)),
            tcp: true)
        defer { server.stop() }
        server.answer = { request in
            let paths = (request["args"] as? [String: Any])?["paths"] as? [String] ?? []
            return ["id": request["id"] ?? "", "status": "ok", "data": ["existing": paths]]
        }
        let paths = (0..<450).map { "/repo/.worktrees/w\($0)" }
        let found = try await BenchdHost(endpoint: server.endpoint).existing(paths)
        XCTAssertEqual(found, Set(paths))
        XCTAssertEqual(server.requests.count, 3)
        for request in server.requests {
            XCTAssertLessThan(
                try JSONSerialization.data(withJSONObject: request).count,
                64 * 1024, "every line under benchd's 64 KB cap")
        }
    }
}

/// Accepts one connection, reads its line, and closes it without answering.
private final class TCPOneShot: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound, listen(fd, 1) == 0 else { throw XCTSkip("cannot listen on loopback") }
        port = UInt16(bigEndian: address.sin_port)
        let listener = fd
        Thread {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var byte: UInt8 = 0
            while read(connection, &byte, 1) == 1, byte != 0x0A {}
            Darwin.close(connection)
        }.start()
    }

    func close() { Darwin.close(fd) }
}
