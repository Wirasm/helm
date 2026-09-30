import XCTest

@testable import Helm

final class WorktreeCLITests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var linked: URL!
    private var git: URL!
    private var calls: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helm-worktree-cli-tests-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("workspace")
        linked = root.appendingPathComponent("linked tree;literal")
        git = root.appendingPathComponent("git")
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
            host: LocalBenchHost(
                environment: environment, gitExecutable: git.path, homeDirectory: root.path),
            timeout: timeout)
    }

    /// The repository-wide reads are one call each whatever the number of worktrees, and the
    /// only per-row call is `git status`, which never takes the index lock. What each answer
    /// means is `WorktreeGitTests`', against real git.
    func testOneCallPerRepositoryWideReadAndOneStatusPerWorktree() async throws {
        try install(
            """
            printf '<call>\\n' >> "$CALLS"
            printf '%s\\n' "$@" >> "$CALLS"
            if [ "$3" = worktree ]; then
              printf 'worktree %s\\nHEAD aaaa\\nbranch refs/heads/development\\n\\n' "$WORKSPACE"
              printf 'worktree %s\\nHEAD bbbb\\nbranch refs/heads/feature/one\\n\\n' "$LINKED"
            elif [ "$3" = symbolic-ref ]; then
              printf 'refs/remotes/origin/development\\n'
            elif [ "$4" = --merged ]; then
              printf 'refs/heads/development\\n'
            elif [ "$1" = --no-optional-locks ] && [ "$3" = "$LINKED" ]; then
              printf ' M file\\n'
            fi
            """, at: git)

        let rows = try await client().worktrees(
            in: GitCommonDir(workspace.path), statusOfALoneCheckout: true)

        XCTAssertEqual(rows.map(\.mergedState), [.merged, .unmerged])
        XCTAssertEqual(rows.map(\.status.isDirty), [false, true])
        let recorded = try String(contentsOf: calls, encoding: .utf8)
        XCTAssertEqual(recorded.components(separatedBy: "<call>").count - 1, 4 + rows.count)
        XCTAssertTrue(recorded.contains("\(workspace.path)\nworktree\nlist\n--porcelain"))
        XCTAssertTrue(
            recorded.contains(
                "for-each-ref\n--merged\nrefs/remotes/origin/development\n--format=%(refname)"))
        XCTAssertTrue(recorded.contains("--no-optional-locks\n-C\n\(linked.path)\nstatus"))
    }

    /// A repository whose main checkout is its only worktree has its status read only when
    /// asked: the drawer does not show such a repository unless a workspace is in it.
    func testALoneCheckoutsStatusIsReadOnlyWhenAsked() async throws {
        try install(
            """
            printf '%s\\n' "$1" >> "$CALLS"
            if [ "$3" = worktree ]; then
              printf 'worktree %s\\nHEAD aaaa\\nbranch refs/heads/main\\n\\n' "$WORKSPACE"
            fi
            """, at: git)
        let repository = GitCommonDir(workspace.path)

        let skipped = try await client().worktrees(in: repository, statusOfALoneCheckout: false)
        XCTAssertNil(skipped.first?.status.isDirty)
        XCTAssertFalse(
            try String(contentsOf: calls, encoding: .utf8).contains("--no-optional-locks"))

        let read = try await client().worktrees(in: repository, statusOfALoneCheckout: true)
        XCTAssertEqual(read.first?.status.isDirty, false)
        XCTAssertTrue(
            try String(contentsOf: calls, encoding: .utf8).contains("--no-optional-locks"))
    }

    func testNoRemoteDefaultLeavesMergedStateUnknown() async throws {
        try install(
            """
            if [ "$3" = worktree ]; then
              printf 'worktree %s\\nHEAD aaaa\\nbranch refs/heads/development\\n\\n' "$WORKSPACE"
            elif [ "$1" = --no-optional-locks ]; then
              exit 128
            else
              printf 'no default\\n' >&2
              exit 2
            fi
            """, at: git)

        let rows = try await client().worktrees(
            in: GitCommonDir(workspace.path), statusOfALoneCheckout: true)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.mergedState, .unknown)
        XCTAssertNil(row.status.isDirty, "a status failure is the row's own, and unknown")
        XCTAssertNil(row.status.tracking)
    }

    /// Force only when the operator was told about uncommitted files; the literal path is one
    /// argument; and an unmerged branch is never touched.
    func testRemoveForcesOnlyForConfirmedUncommittedFilesAndKeepsAnUnmergedBranch() async throws {
        try install("printf '%s ' \"$@\" >> \"$CALLS\"; printf '\\n' >> \"$CALLS\"\n", at: git)
        let row = Worktree.fixture(path: linked.path, branch: "feat/x", mergedState: .unmerged)
        let repository = GitCommonDir(workspace.path)
        func loss(_ files: Int) -> WorktreeLoss {
            WorktreeLoss(
                uncommittedFiles: files, unmergedCommits: 2, branch: "feat/x",
                defaultBranch: "refs/remotes/origin/main")
        }

        try await client().remove(row, in: repository, knowing: loss(0))
        try await client().remove(row, in: repository, knowing: loss(3))

        XCTAssertEqual(
            try String(contentsOf: calls, encoding: .utf8),
            """
            -C \(workspace.path) worktree remove \(linked.path) \n\
            -C \(workspace.path) worktree remove --force \(linked.path) \n
            """, "no prune for a worktree that exists: it would clear other records unasked")
    }

    /// Archon's own cleanup, in the worktree's Archon home, from the main checkout, never
    /// forced; what it prints comes back, because its exit status does not say what it did.
    func testArchonCompleteRunsInItsHomeFromTheMainCheckoutUnforced() async throws {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try install(
            """
            printf '%s|%s|%s\\n' "$*" "$PWD" "$ARCHON_HOME" > "$CALLS"
            printf '  Blocked: %s\\n' "$2" >&2
            """, at: bin.appendingPathComponent("archon"))

        let said = try await client(extraEnvironment: ["PATH": bin.path + ":/usr/bin:/bin"])
            .archonComplete(branch: "archon/task-1", home: "/h/.archon-demo", main: workspace.path)

        let fields = try String(contentsOf: calls, encoding: .utf8)
            .trimmingCharacters(in: .newlines).components(separatedBy: "|")
        XCTAssertEqual(fields.first, "complete archon/task-1")
        XCTAssertTrue(fields[1].hasSuffix("/workspace"), "run from the main checkout: \(fields[1])")
        XCTAssertEqual(fields.last, "/h/.archon-demo")
        XCTAssertEqual(said, "Blocked: archon/task-1")
    }

    /// Where a new worktree goes turns on `git check-ignore`: status 1 is "not ignored", so the
    /// sibling folder; a failure that is not an answer (here 128) stops the create rather than
    /// quietly choosing the sibling.
    func testCheckIgnoreDecidesThePlaceOnlyWhenItAnswers() async throws {
        let body: (Int) -> String = { status in
            """
            case "$*" in
              *check-ignore*) exit \(status) ;;
              *show-ref*|*symbolic-ref*) exit 1 ;;
            esac
            printf '%s\\n' "$*" >> "$CALLS"
            """
        }
        let repository = GitCommonDir(workspace.path + "/.git")
        try install(body(1), at: git)
        let path = try await client().create(branch: "feat/a", in: repository, main: workspace.path)
        XCTAssertFalse(path.contains("/.worktrees/"), path)

        try install(body(128), at: git)
        do {
            _ = try await client().create(branch: "feat/b", in: repository, main: workspace.path)
            XCTFail("a check-ignore that did not answer must not place the worktree")
        } catch let error as WorktreeCLIError {
            XCTAssertTrue(error.command.contains("check-ignore"), error.command)
        }
    }

    func testGitFailureCarriesExitStatusBoundedStderrAndCommand() async throws {
        try install(
            "i=0; while [ $i -lt 200 ]; do printf 'refused noise ' >&2; i=$((i+1)); done; exit 7\n",
            at: git)

        do {
            _ = try await client().worktrees(
                in: GitCommonDir(workspace.path), statusOfALoneCheckout: true)
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
        let budget = Duration.seconds(2)
        // Built outside the `Task` so the closure captures only the client and the path —
        // capturing `self` to reach the `client(…)` helper is a `sending` violation. The
        // cancellation test below is shaped this way for the same reason.
        let client = client(extraEnvironment: ["PID_RECORD": pidRecord.path], timeout: budget)
        let repository = GitCommonDir(workspace.path)
        let call = Task { try await client.worktrees(in: repository, statusOfALoneCheckout: true) }
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
        let client = client(extraEnvironment: ["PID_RECORD": pidRecord.path])
        let repository = GitCommonDir(workspace.path)
        let call = Task { try await client.worktrees(in: repository, statusOfALoneCheckout: true) }
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

    /// Waiting on a child must not hold a thread of Swift's cooperative pool. The pool has one
    /// thread per core; the old runner parked one in `waitUntilExit()` per `git`/`du` child, so a
    /// refresh across a few repositories could stop every other `async` task in helm until
    /// git answered (#377).
    ///
    /// Synchronous on purpose: the test body must not need the pool it is checking. The children
    /// wait on a gate the test opens itself, so nothing here depends on a sleep staying inside a
    /// deadline. The probe gets 10s to run while every child is parked; on the old runner it
    /// cannot run at all until the escape hatch opens the gate.
    func testWaitingOnChildrenHoldsNoThreadOfTheCooperativePool() throws {
        let gate = root.appendingPathComponent("gate")
        let started = root.appendingPathComponent("started")
        try FileManager.default.createDirectory(at: started, withIntermediateDirectories: true)
        // Bounded by its own deadline (600 × 50ms), so a child outlives a crashed test by 30s
        // at most.
        try install(
            """
            touch "$STARTED/$$"
            i=0
            while [ ! -f "$GATE" ] && [ $i -lt 600 ]; do /bin/sleep 0.05; i=$((i+1)); done
            """, at: git)
        defer { FileManager.default.createFile(atPath: gate.path, contents: nil) }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let client = client(extraEnvironment: ["GATE": gate.path, "STARTED": started.path])
        let repository = GitCommonDir(workspace.path)
        let finished = expectation(description: "every call returned")
        finished.expectedFulfillmentCount = cores * 2
        for _ in 0..<(cores * 2) {
            Task.detached {
                _ = try? await client.worktrees(in: repository, statusOfALoneCheckout: true)
                finished.fulfill()
            }
        }

        // At least a pool's width of children, so on the old runner every pool thread is parked.
        let deadline = Date().addingTimeInterval(20)
        while (try? FileManager.default.contentsOfDirectory(atPath: started.path).count) ?? 0
            < cores, Date() < deadline
        {
            usleep(20_000)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            FileManager.default.createFile(atPath: gate.path, contents: nil)
        }
        let probed = expectation(description: "the probe ran")
        let gateWasOpen = LockedFlag()
        Task.detached {
            gateWasOpen.set(FileManager.default.fileExists(atPath: gate.path))
            probed.fulfill()
        }
        wait(for: [probed], timeout: 30)
        XCTAssertFalse(
            gateWasOpen.value,
            "an async task could not run while \(cores) children were being waited on — the "
                + "runner is holding cooperative-pool threads")

        FileManager.default.createFile(atPath: gate.path, contents: nil)
        wait(for: [finished], timeout: 30)
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool { lock.withLock { stored } }
        func set(_ newValue: Bool) { lock.withLock { stored = newValue } }
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
