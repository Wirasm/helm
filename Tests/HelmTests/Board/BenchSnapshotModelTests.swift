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
        XCTAssertEqual(pane?.terminal?.owner?.handle, "owner-4242")
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

    func testPeriodicRefreshPublishesWithoutAModelChangeAndStops() async throws {
        var writes: [BenchSnapshot] = []
        let (model, workspaces, workbench, terminals) = fixture(
            refreshInterval: .milliseconds(5),
            writer: {
                writes.append($0)
                return true
            })
        model.start(workspaces: workspaces, workbench: workbench, terminals: terminals)

        try await Task.sleep(for: .milliseconds(25))
        XCTAssertGreaterThanOrEqual(writes.count, 2)

        model.stop()
        let writesAfterStop = writes.count
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(writes.count, writesAfterStop)
    }
}
