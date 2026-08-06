import XCTest

@testable import Helm

final class WorktreeCLITests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var linked: URL!
    private var git: URL!
    private var du: URL!
    private var calls: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helm-worktree-cli-tests-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("workspace")
        linked = root.appendingPathComponent("linked tree;literal")
        git = root.appendingPathComponent("git")
        du = root.appendingPathComponent("du")
        calls = root.appendingPathComponent("calls")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func install(_ body: String, at url: URL) throws {
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func client(
        extraEnvironment: [String: String] = [:], timeout: Duration = WorktreeCLI.defaultTimeout
    ) -> WorktreeCLI {
        var environment = [
            "WORKSPACE": workspace.path, "LINKED": linked.path, "CALLS": calls.path,
        ]
        environment.merge(extraEnvironment) { _, new in new }
        return WorktreeCLI(
            environment: environment, gitExecutable: git.path, duExecutable: du.path,
            timeout: timeout)
    }

    func testListsWithPorcelainAndEnrichesAgainstAnExplicitRemoteDefault() async throws {
        try install(
            """
            printf '<call>\\n' >> "$CALLS"
            printf '%s\\n' "$@" >> "$CALLS"
            if [ "$3" = worktree ]; then
              printf 'worktree %s\\nHEAD aaaa\\nbranch refs/heads/development\\n\\n' "$WORKSPACE"
              printf 'worktree %s\\nHEAD bbbb\\nbranch refs/heads/feature/one\\n\\n' "$LINKED"
            elif [ "$3" = symbolic-ref ]; then
              printf 'refs/remotes/origin/development\\n'
            elif [ "$5" = refs/heads/feature/one ]; then
              exit 1
            fi
            """, at: git)
        try install("printf '8\\t%s\\n' \"$2\"\n", at: du)

        let rows = try await client().worktrees(in: WorkspacePath(workspace))

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].isMain)
        XCTAssertEqual(rows[0].mergedState, .merged)
        XCTAssertEqual(rows[1].mergedState, .unmerged)
        XCTAssertEqual(rows[1].metadata.diskBytes, 8 * 1_024)
        let recorded = try String(contentsOf: calls, encoding: .utf8)
        XCTAssertTrue(recorded.contains("worktree\nlist\n--porcelain"))
        XCTAssertTrue(recorded.contains("symbolic-ref\n--quiet\nrefs/remotes/origin/HEAD"))
        XCTAssertTrue(
            recorded.contains(
                "merge-base\n--is-ancestor\nrefs/heads/feature/one\nrefs/remotes/origin/development"
            ))
    }

    func testNoRemoteDefaultLeavesMergedStateUnknown() async throws {
        try install(
            """
            if [ "$3" = worktree ]; then
              printf 'worktree %s\\nHEAD aaaa\\nbranch refs/heads/development\\n\\n' "$WORKSPACE"
            else
              printf 'no default\\n' >&2
              exit 2
            fi
            """, at: git)
        try install("exit 1\n", at: du)

        let rows = try await client().worktrees(in: WorkspacePath(workspace))
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.mergedState, .unknown)
        XCTAssertNil(row.metadata.diskBytes, "a du failure is local to the row")
    }

    func testRemovePassesTheLiteralPathAndNeverForce() async throws {
        try install("printf '%s\\n' \"$@\" > \"$CALLS\"\n", at: git)
        try install("exit 0\n", at: du)

        try await client().remove(path: linked.path, in: WorkspacePath(workspace))

        XCTAssertEqual(
            try String(contentsOf: calls, encoding: .utf8),
            "-C\n\(workspace.path)\nworktree\nremove\n\(linked.path)\n")
    }

    func testGitFailureCarriesExitStatusBoundedStderrAndCommand() async throws {
        try install(
            "i=0; while [ $i -lt 200 ]; do printf 'refused noise ' >&2; i=$((i+1)); done; exit 7\n",
            at: git)
        try install("exit 0\n", at: du)

        do {
            _ = try await client().worktrees(in: WorkspacePath(workspace))
            XCTFail("expected failure")
        } catch let error as WorktreeCLIError {
            XCTAssertEqual(error.command, "git -C \(workspace.path) worktree list --porcelain")
            guard case let .nonzeroExit(status, stderr) = error.reason else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(status, 7)
            XCTAssertEqual(stderr.count, WorktreeCLI.errorSnippetLimit + 1)
        }
    }

    /// **The timeout has to outlast the fake git's own start-up, not merely the work.**
    /// This raced at 300ms: the child is killed when the timeout fires whether or not it has
    /// reached its first `printf`, so on a loaded machine `git-pid` was never written and
    /// `assertChildIsGone` read a file that did not exist — surfacing as an `XCTUnwrap` on
    /// `NSCocoaErrorDomain 260` rather than as the scheduling delay it was. Measured at one
    /// failure in five full-suite runs. `waitForPid` proves the child really started, the way
    /// the cancellation test below already did; the wider budget is what stops the timeout
    /// winning that race in the first place.
    func testHungListTimesOutAndTerminatesItsGitChild() async throws {
        let pidRecord = root.appendingPathComponent("git-pid")
        try install("printf '%s' \"$$\" > \"$PID_RECORD\"\nexec /bin/sleep 999\n", at: git)
        try install("exit 0\n", at: du)
        let budget = Duration.seconds(2)
        // Built outside the `Task` so the closure captures only the client and the path —
        // capturing `self` to reach the `client(…)` helper is a `sending` violation. The
        // cancellation test below is shaped this way for the same reason.
        let client = client(extraEnvironment: ["PID_RECORD": pidRecord.path], timeout: budget)
        let workspacePath = WorkspacePath(workspace)
        let call = Task { try await client.worktrees(in: workspacePath) }
        try await waitForPid(pidRecord)

        do {
            _ = try await call.value
            XCTFail("expected timeout")
        } catch let error as WorktreeCLIError {
            XCTAssertEqual(error.reason, .timedOut(after: budget))
        }
        try assertChildIsGone(pidRecord)
    }

    func testCancellingListTerminatesItsGitChild() async throws {
        let pidRecord = root.appendingPathComponent("git-pid")
        try install("printf '%s' \"$$\" > \"$PID_RECORD\"\nexec /bin/sleep 999\n", at: git)
        try install("exit 0\n", at: du)
        let client = client(extraEnvironment: ["PID_RECORD": pidRecord.path])
        let workspacePath = WorkspacePath(workspace)
        let call = Task { try await client.worktrees(in: workspacePath) }
        try await waitForPid(pidRecord)
        call.cancel()

        do {
            _ = try await call.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("wrong error: \(error)")
        }
        try assertChildIsGone(pidRecord)
    }

    private func waitForPid(_ record: URL) async throws {
        for _ in 0..<250 {
            if let text = try? String(contentsOf: record, encoding: .utf8), Int32(text) != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the fake git never started")
    }

    private func assertChildIsGone(_ record: URL) throws {
        let pid = try XCTUnwrap(Int32(try String(contentsOf: record, encoding: .utf8)))
        for _ in 0..<250 {
            if kill(pid, 0) != 0 { return }
            usleep(20_000)
        }
        XCTFail("pid \(pid) survived")
    }
}
