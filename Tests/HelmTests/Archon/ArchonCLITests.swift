import XCTest

@testable import Helm

final class ArchonCLITests: XCTestCase {
    private var root: URL!
    private var bin: URL!
    private var captures: URL!
    private var workspace: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helm-archon-cli-tests-\(UUID().uuidString)")
        bin = root.appendingPathComponent("bin")
        captures = root.appendingPathComponent("captures")
        workspace = root.appendingPathComponent("workspace")
        for directory in [bin!, captures!, workspace!] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func install(_ body: String) throws {
        let script = bin.appendingPathComponent("archon")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    private func cli(
        extraEnvironment: [String: String] = [:], timeout: Duration = .seconds(20)
    ) -> ArchonCLI {
        var environment = extraEnvironment
        environment["PATH"] = bin.path
        return ArchonCLI(
            inheritedEnvironment: environment,
            homeDirectory: root.appendingPathComponent("home").path,
            captureDirectory: captures,
            timeout: timeout)
    }

    // MARK: - What reaches the process

    /// The working directory is the assertion that matters here. `archon` resolves its project
    /// from it and exits 1 with "Not in a git repository" otherwise — and helm's own cwd is `/`
    /// when the `.app` is opened from the Dock, so a call that does not set it fails every
    /// time, on the shipped build only.
    func testRunsInTheWorkspaceOnTheDevelopmentPathAndDeletesItsCapture() async throws {
        let record = root.appendingPathComponent("record")
        // A marker written into the *current* directory, rather than a comparison of `$PWD`
        // against the path helm passed: /var is a symlink to /private/var on macOS and
        // `resolvingSymlinksInPath()` deliberately does not follow it, so the two spellings of
        // one directory would never be string-equal. A file that lands there is unambiguous.
        try install(
            "printf 'here' > cwd-marker\n"
                + "printf '%s\\n' \"$PATH\" > \"$RECORD\"\n"
                + "printf '%s\\n' \"$@\" >> \"$RECORD\"\n"
                + "printf '{\"runs\":[],\"total\":0,\"counts\":{},\"scopeFallback\":false}'\n")

        let response = try await cli(extraEnvironment: ["RECORD": record.path])
            .runs(in: workspace.path)

        XCTAssertEqual(response.runs, [])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("cwd-marker").path),
            "the child runs IN the workspace — that is how Archon picks the project")
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
        XCTAssertTrue(
            lines[0].hasPrefix(root.appendingPathComponent("home/.bun/bin").path + ":"),
            "a GUI app inherits launchd's PATH, which has never heard of a bun global")
        XCTAssertEqual(Array(lines[1...3]), ["workflow", "runs", "--json"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: captures.path), [])
    }

    func testEveryCommandComposesItsPublishedArguments() async throws {
        let argsRecord = root.appendingPathComponent("args")
        try install(
            "printf '%s\\n' \"$@\" > \"$ARGS_RECORD\"\ncase \"$2\" in "
                + "list) printf '{\"workflows\":[],\"errors\":[]}' ;; "
                + "get) printf '{\"id\":\"r1\",\"workflow_name\":\"ship\",\"status\":\"running\"}' ;; "
                + "runs) printf '{\"runs\":[],\"total\":0,\"counts\":{},\"scopeFallback\":false}' ;; "
                + "run) printf '{\"ok\":true,\"action\":\"run\",\"detached\":true,\"workflow\":"
                + "\"ship\",\"branch\":\"b\",\"conversationId\":\"c\",\"logPath\":null}' ;; esac\n")
        let client = cli(extraEnvironment: ["ARGS_RECORD": argsRecord.path])

        _ = try await client.workflows(in: workspace.path)
        XCTAssertEqual(try String(contentsOf: argsRecord), "workflow\nlist\n--json\n")

        _ = try await client.run(id: "r1", in: workspace.path)
        XCTAssertEqual(try String(contentsOf: argsRecord), "workflow\nget\nr1\n--json\n--verbose\n")

        _ = try await client.runs(in: workspace.path)
        XCTAssertEqual(try String(contentsOf: argsRecord), "workflow\nruns\n--json\n")

        _ = try await client.launch(
            .init(
                workspacePath: workspace.path, workflow: "ship", input: "do it",
                worktree: .branch("b")))
        XCTAssertEqual(
            try String(contentsOf: argsRecord),
            "workflow\nrun\nship\ndo it\n--detach\n--json\n--branch\nb\n")

        _ = try await client.launch(
            .init(
                workspacePath: workspace.path, workflow: "ship", input: "do it", worktree: .none))
        XCTAssertEqual(
            try String(contentsOf: argsRecord),
            "workflow\nrun\nship\ndo it\n--detach\n--json\n--no-worktree\n")

        _ = try await client.launch(
            .init(
                workspacePath: workspace.path, workflow: "ship", input: "do it",
                worktree: .automatic))
        XCTAssertEqual(
            try String(contentsOf: argsRecord),
            "workflow\nrun\nship\ndo it\n--detach\n--json\n",
            "no flag at all is a real choice: Archon mints the branch and cuts the worktree")
    }

    func testCompleteUsesTheWorkspaceAndExactUnforcedArguments() async throws {
        let argsRecord = root.appendingPathComponent("complete-args")
        try install(
            "printf '%s\\n' \"$@\" > \"$ARGS_RECORD\"\n"
                + "printf 'Completed archon/task-141\\n'\n")

        try await cli(extraEnvironment: ["ARGS_RECORD": argsRecord.path])
            .complete(branch: "archon/task-141", in: workspace.path)

        XCTAssertEqual(
            try String(contentsOf: argsRecord, encoding: .utf8),
            "complete\narchon/task-141\n")
        XCTAssertFalse(try String(contentsOf: argsRecord).contains("force"))
    }

    func testCompleteTreatsNotFoundTextAsARefusal() async throws {
        try install("printf 'Not found: archon/task-missing\\n'\n")

        do {
            try await cli().complete(branch: "archon/task-missing", in: workspace.path)
            XCTFail("expected refusal")
        } catch let error as ArchonCLIError {
            XCTAssertEqual(
                error.reason, .actionRejected("Not found: archon/task-missing"))
            XCTAssertEqual(error.command, "archon complete archon/task-missing")
        }
    }

    // MARK: - What a failure carries

    /// "archon is not installed" used to surface as a bare `nonzeroExit(127)`. Everything that
    /// makes it actionable — which call, and Archon's own sentence about why — was being sent
    /// to `nullDevice` and dropped on the floor.
    func testAFailedCallCarriesTheCommandAndArchonsOwnStderr() async throws {
        try install("printf 'Error: Not in a git repository.\\n' >&2\nexit 1\n")

        do {
            _ = try await cli().runs(in: workspace.path)
            XCTFail("expected failure")
        } catch let error as ArchonCLIError {
            XCTAssertEqual(error.command, "archon workflow runs --json")
            XCTAssertEqual(
                error.reason, .nonzeroExit(status: 1, stderr: "Error: Not in a git repository."))
            XCTAssertTrue(
                error.localizedDescription.contains("Not in a git repository"),
                "the operator reads this string, so the actionable half has to be in it")
        }
    }

    func testTheStderrSnippetIsBounded() async throws {
        try install(
            "i=0\nwhile [ $i -lt 200 ]\ndo printf 'noise noise noise\\n' >&2\ni=$((i+1))\ndone\nexit 3\n"
        )

        do {
            _ = try await cli().runs(in: workspace.path)
            XCTFail("expected failure")
        } catch let error as ArchonCLIError {
            guard case let .nonzeroExit(_, stderr) = error.reason else {
                return XCTFail("wrong reason: \(error.reason)")
            }
            XCTAssertEqual(
                stderr.count, ArchonCLI.errorSnippetLimit + 1,
                "bounded plus the ellipsis — a stack trace must not become the UI")
        }
    }

    func testEmptyIsDistinctFromMalformedAndOnlyMalformedKeepsTheBytes() async throws {
        try install("exit 0\n")
        do {
            _ = try await cli().runs(in: workspace.path)
            XCTFail("expected failure")
        } catch let error as ArchonCLIError {
            XCTAssertEqual(error.reason, .emptyOutput)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: captures.path), [])

        try install("printf 'not json'\n")
        do {
            _ = try await cli().runs(in: workspace.path)
            XCTFail("expected failure")
        } catch let error as ArchonCLIError {
            guard case let .malformedJSON(_, capturedAt) = error.reason else {
                return XCTFail("wrong reason: \(error.reason)")
            }
            // The one outcome where the payload IS the evidence: this PR shipped a decoder
            // built from an imagined shape, and there was nothing on disk to check it against.
            let path = try XCTUnwrap(capturedAt)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "not json")
        }
    }

    // MARK: - What happens when it does not come back

    func testAHungCallIsCutOffByTheDeadlineAndTheChildDies() async throws {
        let pidRecord = root.appendingPathComponent("pid")
        try installSleeper()

        let started = ContinuousClock.now
        do {
            _ = try await cli(
                extraEnvironment: ["PID_RECORD": pidRecord.path], timeout: .milliseconds(300)
            ).runs(in: workspace.path)
            XCTFail("expected failure")
        } catch let error as ArchonCLIError {
            guard case .timedOut = error.reason else {
                return XCTFail("wrong reason: \(error.reason)")
            }
        }

        XCTAssertLessThan(
            ContinuousClock.now - started, .seconds(10),
            "one hung call used to leave isRefreshing true for the life of the process")
        try assertChildIsGone(pidRecord)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: captures.path), [])
    }

    /// Cancelling a poll — which is what closing a pane or switching workspace does — has to
    /// reach the subprocess. It could not before: `Task.detached` is unstructured, so the
    /// cancellation never arrived and `waitUntilExit()` held on to an orphaned child.
    func testCancellingTheTaskTerminatesTheChild() async throws {
        let pidRecord = root.appendingPathComponent("pid")
        try installSleeper()
        let client = cli(extraEnvironment: ["PID_RECORD": pidRecord.path])
        let workspacePath = workspace.path

        let call = Task { try await client.runs(in: workspacePath) }
        try await waitForPid(pidRecord)
        call.cancel()

        let started = ContinuousClock.now
        do {
            _ = try await call.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        try assertChildIsGone(pidRecord)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: captures.path), [])
    }

    /// `exec` so the process helm launched *is* the sleeping one. A `/bin/sh` that forked a
    /// `sleep` would be killed while its child lived on — which is the orphaning this whole
    /// mechanism exists to stop, so a test that could not see it would be worthless.
    private func installSleeper() throws {
        // `/bin/sleep` by absolute path: the fake PATH holds only the fake `archon` and a
        // `~/.bun/bin` that does not exist, so a bare `sleep` is not found and the child
        // would exit 127 instead of hanging — which is the one thing this test needs it to do.
        try install("printf '%s' \"$$\" > \"$PID_RECORD\"\nexec /bin/sleep 999\n")
    }

    private func waitForPid(_ record: URL) async throws {
        for _ in 0..<250 {
            if let text = try? String(contentsOf: record, encoding: .utf8), Int32(text) != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the fake archon never started")
    }

    private func assertChildIsGone(_ record: URL) throws {
        let pid = try XCTUnwrap(Int32(try String(contentsOf: record, encoding: .utf8)))
        for _ in 0..<250 {
            if kill(pid, 0) != 0 { return }
            usleep(20_000)
        }
        XCTFail("pid \(pid) survived — the child was orphaned rather than terminated")
    }
}
