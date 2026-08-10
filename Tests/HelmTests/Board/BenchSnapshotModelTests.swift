import XCTest

@testable import Helm

@MainActor
final class BenchSnapshotModelTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-bench-model-\(UUID().uuidString)")
        defaults = try isolatedDefaults("bench-snapshot-model")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults = nil
        root = nil
    }

    private func fixture(
        refreshInterval: Duration = .seconds(60),
        now: @escaping () -> Date = Date.init,
        foregroundPid: @escaping (TerminalSession) -> pid_t? = { _ in nil },
        writer: BenchSnapshotModel.Writer? = nil
    ) -> (BenchSnapshotModel, WorkspaceModel, WorkbenchModel, TerminalManager) {
        let terminals = TerminalManager()
        let workbench = WorkbenchModel(terminals: terminals)
        let workspaces = WorkspaceModel(defaults: defaults)
        workspaces.open(Workspace(path: "/tmp/bench-snapshot-model"))
        workbench.activate(workspacePath: WorkspacePath("/tmp/bench-snapshot-model"))
        let model = BenchSnapshotModel(
            directory: BenchSnapshotDirectory(root: root),
            mailboxRoot: root.appendingPathComponent("mail"),
            // Never the operator's real `~/.claude/sessions`: a test that reads it measures the
            // machine it runs on, and #247 made this model read a registry at all.
            registryRoot: root.appendingPathComponent("sessions"),
            refreshInterval: refreshInterval,
            now: now,
            foregroundPid: foregroundPid,
            writer: writer)
        return (model, workspaces, workbench, terminals)
    }

    func testStartWritesImmediatelyAndDuplicateStartDoesNotWriteAgain() {
        var writes: [BenchSnapshot] = []
        let (model, workspaces, workbench, terminals) = fixture(writer: { value in
            writes.append(value)
            return true
        })

        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)
        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)

        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0].workspaces[0].state, .mounted)
        model.stop()
    }

    /// **`writtenAt` is a change signal, not a heartbeat (#267).** The file is rebuilt on a
    /// timer as well as on change, so before this it advanced every couple of seconds whether or
    /// not anything had happened — and an agent diffing it to answer *did my push land?* saw a
    /// change every time. Measured that way by a capability test, with a no-edit control run.
    ///
    /// The timer still *runs*: it is what notices a mailbox or a registry row appearing, neither
    /// of which publishes `objectWillChange`. It just no longer writes when the answer is the
    /// same.
    func testTheTimerDoesNotRewriteAnUnchangedSnapshot() async throws {
        var writes: [BenchSnapshot] = []
        var instant = Date(timeIntervalSince1970: 10)
        let (model, workspaces, workbench, terminals) = fixture(
            refreshInterval: .milliseconds(20),
            now: { instant },
            writer: { value in
                writes.append(value)
                instant = instant.addingTimeInterval(10)
                return true
            })

        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)
        XCTAssertEqual(writes.count, 1, "start publishes once")

        // The real timer, firing several times over. Time advances on every publish; nothing
        // else does.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            writes.count, 1,
            "a rebuild that differs only in `writtenAt` is not news, and writing it makes every "
                + "reader diffing that field see a change that did not happen")
        model.stop()
    }

    /// The other half, and it must pass either way — a model that never writes anything also
    /// passes the test above. This one fails if the skip overshoots.
    func testARealChangeIsStillWritten() async throws {
        var writes: [BenchSnapshot] = []
        let (model, workspaces, workbench, terminals) = fixture(
            refreshInterval: .milliseconds(20),
            writer: { value in
                writes.append(value)
                return true
            })

        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)
        try await Task.sleep(for: .milliseconds(60))
        let quiet = writes.count

        workspaces.open(Workspace(path: "/tmp/bench-snapshot-model-second"))
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertGreaterThan(
            writes.count, quiet, "opening a workspace is content, and content is written")
        XCTAssertGreaterThan(
            writes.last?.workspaces.count ?? 0, writes[0].workspaces.count)
        model.stop()
    }

    func testWorkbenchAndTerminalBurstPublishesSettledStateOnce() async throws {
        var writes: [BenchSnapshot] = []
        var instant = Date(timeIntervalSince1970: 10)
        let (model, workspaces, workbench, terminals) = fixture(
            now: { instant },
            writer: {
                writes.append($0)
                return true
            })
        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)

        instant = Date(timeIntervalSince1970: 11)
        let session = try XCTUnwrap(workbench.newTerminal())
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(writes.count, 2, "terminal and bench notifications are one logical change")
        let panes = writes.last?.workspaces[0].columns.flatMap { $0.slots.flatMap(\.panes) }
        XCTAssertTrue(
            panes?.contains { $0.id == session.id && $0.terminal?.isLive == true } == true)
        XCTAssertEqual(writes.last?.writtenAt, instant)
        model.stop()
    }

    func testWorkspaceSwitchAndClosePublishSettledWorkspaceState() async {
        var writes: [BenchSnapshot] = []
        let (model, workspaces, workbench, terminals) = fixture(writer: {
            writes.append($0)
            return true
        })
        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)

        let second = Workspace(path: "/tmp/bench-snapshot-model-second")
        workspaces.open(second)
        workbench.activate(workspacePath: second.path)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(
            writes.last?.workspaces.first { $0.path == second.path }?.state, .mounted)

        workspaces.close(second)
        workbench.deactivate()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(writes.last?.workspaces.contains { $0.path == second.path } ?? true)
        model.stop()
    }

    func testRefreshPicksUpMailboxOwnerAndMalformedRowsDoNotBlockIt() throws {
        let mail = root.appendingPathComponent("mail")
        try FileManager.default.createDirectory(
            at: mail.appendingPathComponent("bad"), withIntermediateDirectories: true)
        try "not json".write(
            to: mail.appendingPathComponent("bad/owner.json"),
            atomically: true,
            encoding: .utf8)
        var writes: [BenchSnapshot] = []
        let (model, workspaces, workbench, terminals) = fixture(
            foregroundPid: { _ in 4242 },
            writer: {
                writes.append($0)
                return true
            })
        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)

        let good = mail.appendingPathComponent("good")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try #"{"handle":"owner-4242","runtime":"codex","pid":4242,"sessionId":"s","cwd":"/tmp"}"#
            .write(to: good.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)

        model.refresh()

        XCTAssertEqual(writes.count, 2)
        let pane = writes.last?.workspaces[0].columns[0].slots[0].panes[0]
        XCTAssertEqual(pane?.terminal?.owner?.handle.value, "owner-4242")
        model.stop()
    }

    /// **The wiring, not the rule.** `AddressBook` is where "ask the session, not the pid" is
    /// decided and `MailboxDirectoryTests` is where it is pinned — but a model that built its
    /// book with `sessionFor: { _ in nil }` would satisfy every one of those tests and still
    /// publish the wrong agent, because nothing else proves this model reads a registry at all.
    ///
    /// So: a live Claude agent whose `owner.json` still names the pid it started under, and a
    /// registry row saying where that session actually is now. Only reading the registry joins
    /// them.
    func testTheSnapshotResolvesAPaneThroughTheSessionRegistryAndNotItsRecordedPid() throws {
        let mail = root.appendingPathComponent("mail/helm-4831")
        try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
        let record =
            #"{"handle":"helm-4831","runtime":"claude","pid":13104,"#
            + #""sessionId":"s-4831","cwd":"/tmp"}"#
        try record.write(
            to: mail.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)

        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try #"{"pid":74011,"sessionId":"s-4831","cwd":"/tmp","status":"busy"}"#
            .write(
                to: sessions.appendingPathComponent("74011.json"), atomically: true,
                encoding: .utf8)

        var writes: [BenchSnapshot] = []
        let (model, workspaces, workbench, terminals) = fixture(
            foregroundPid: { _ in 74011 },
            writer: {
                writes.append($0)
                return true
            })
        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)

        let pane = writes.last?.workspaces[0].columns[0].slots[0].panes[0]
        XCTAssertEqual(
            pane?.terminal?.owner?.handle.value, "helm-4831",
            "the pane runs session s-4831 at pid 74011; owner.json still says 13104")
        model.stop()
    }

    /// The registry row a real stall writes, reproduced 2026-08-10 under
    /// `claude --dangerously-skip-permissions` — the spool's unattended posture verbatim — with
    /// the guardrail that posture cannot remove. Kept beside the working row it is told apart
    /// from, because that comparison is the whole point of both.
    private static let stalledRow =
        #"{"pid":41436,"sessionId":"s-1","cwd":"/tmp","status":"waiting","#
        + #""statusUpdatedAt":1786362950614,"waitingFor":"permission prompt"}"#
    private static let workingRow =
        #"{"pid":41436,"sessionId":"s-1","cwd":"/tmp","status":"busy","#
        + #""statusUpdatedAt":1786362900000}"#

    /// **The wiring #283 turns on, end to end through the real model.** `BenchSnapshotTests`
    /// pins the projection rule; a model that passed `agents: [:]` would satisfy every one of
    /// those and still publish a file with nothing in it — which is the state helm was already
    /// in, since it read this very registry every publish and kept only `sessionId`.
    ///
    /// The row is the one a real stall writes, reproduced 2026-08-10 under the spool's own
    /// unattended posture.
    func testTheSnapshotCarriesWhatTheAgentInThePaneSaysItIsWaitingFor() throws {
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Self.stalledRow.write(
            to: sessions.appendingPathComponent("41436.json"), atomically: true, encoding: .utf8)

        var writes: [BenchSnapshot] = []
        let (model, workspaces, workbench, terminals) = fixture(
            foregroundPid: { _ in 41436 },
            writer: {
                writes.append($0)
                return true
            })
        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)

        let agent = writes.last?.workspaces[0].columns[0].slots[0].panes[0].terminal?.agent
        XCTAssertEqual(agent?.status, "waiting")
        XCTAssertEqual(agent?.waitingFor, "permission prompt")
        XCTAssertEqual(
            try XCTUnwrap(agent?.statusUpdatedAt).timeIntervalSince1970, 1_786_362_950.614,
            accuracy: 0.001)
        model.stop()
    }

    /// **An agent going quiet is news, and #267's dedupe must not swallow it.**
    ///
    /// This is the property the ticket asks for in as many words: the signal is in the snapshot
    /// and reading it *"does not require a coordinator to poll `writtenAt`"*. Both halves are
    /// here. Nothing on the bench moved — same workspaces, same panes, same everything the
    /// dedupe compares — and the file is still rewritten, so the last write is the moment the
    /// stall began; after that the record stops changing and `now - statusUpdatedAt` keeps
    /// growing on its own.
    func testAnAgentBlockingOnAPromptIsWrittenEvenThoughNothingOnTheBenchMoved() throws {
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let row = sessions.appendingPathComponent("41436.json")
        try Self.workingRow.write(to: row, atomically: true, encoding: .utf8)

        var writes: [BenchSnapshot] = []
        let (model, workspaces, workbench, terminals) = fixture(
            foregroundPid: { _ in 41436 },
            writer: {
                writes.append($0)
                return true
            })
        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)
        XCTAssertEqual(writes.count, 1)

        // The control: nothing changed anywhere, so nothing is written. Without this the
        // assertion below is satisfied by a model that writes on every publish.
        model.refresh()
        XCTAssertEqual(writes.count, 1, "an unchanged bench and an unchanged agent are not news")

        try Self.stalledRow.write(to: row, atomically: true, encoding: .utf8)
        model.refresh()

        XCTAssertEqual(
            writes.count, 2,
            "the agent stopping is the only thing that changed, and it is the thing a "
                + "coordinator has to be able to see")
        XCTAssertEqual(
            writes.last?.workspaces[0].columns[0].slots[0].panes[0].terminal?.agent?.waitingFor,
            "permission prompt")
        model.stop()
    }

    func testStopPreventsFutureWritesAndFailureCanRetry() async {
        var attempts = 0
        let (model, workspaces, workbench, terminals) = fixture(writer: { _ in
            attempts += 1
            return attempts > 1
        })
        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)
        XCTAssertEqual(attempts, 1, "the initial failure is contained")

        model.refresh()
        XCTAssertEqual(attempts, 2, "a later publication retries")
        model.stop()
        workspaces.select(nil)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(attempts, 2)
    }

    /// **What the timer is for, and what this can and cannot assert (#267).**
    ///
    /// This used to assert the timer publishes *with no model change at all* — true, and exactly
    /// what made `writtenAt` advance every couple of seconds and mean nothing. That behaviour is
    /// gone, so the assertion went with it rather than being kept green by accident.
    ///
    /// The timer still runs, and its reason is real: a **mailbox** and a **registry row** appear
    /// on disk while helm is running and neither publishes `objectWillChange` — `SpoolModel`
    /// waits on precisely that. But an owner only reaches the snapshot **attached to a terminal
    /// pane**, matched on the pane's foreground pid, and this fixture has no pane to attach one
    /// to. So the half this test can state honestly is that the loop stops when the model does;
    /// the noticing half is covered where the panes are, in `BenchSnapshotTests`.
    ///
    /// Said plainly rather than dressed up: a test asserting a fixture it cannot arrange is worth
    /// less than a test saying which half it covers.
    func testTheTimerStopsWhenTheModelDoes() async throws {
        var writes: [BenchSnapshot] = []
        let (model, workspaces, workbench, terminals) = fixture(
            refreshInterval: .milliseconds(5),
            writer: {
                writes.append($0)
                return true
            })
        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)
        try await Task.sleep(for: .milliseconds(25))

        model.stop()
        let writesAfterStop = writes.count
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(writes.count, writesAfterStop)
    }
}
