import XCTest

@testable import Helm

@MainActor
final class BenchSnapshotTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        try isolatedDefaults("bench-snapshot")
    }

    private func mounted(
        workspace: Workspace,
        restoring bench: Workbench? = nil
    ) throws -> (WorkspaceModel, WorkbenchModel, TerminalManager) {
        let terminals = TerminalManager()
        let workbench = WorkbenchModel(terminals: terminals)
        let workspaces = WorkspaceModel(defaults: try defaults())
        workspaces.open(workspace)
        workbench.activate(workspacePath: workspace.path, restoring: bench)
        return (workspaces, workbench, terminals)
    }

    func testProjectionPreservesVisualOrderSelectionVisibilityAndFocus() throws {
        let first = UUID()
        let hidden = UUID()
        let canvas = UUID()
        var bench = Workbench(
            panes: [
                Pane(id: first, content: .terminal(face: .terminal)),
                Pane(id: hidden, content: .terminal(face: .terminal)),
            ],
            selecting: hidden)
        bench.splitRight(with: Pane(id: canvas, content: .canvas(.file("/tmp/plan.md"))))
        let workspace = Workspace(path: "/tmp/bench-snapshot-order")
        let (workspaces, workbench, terminals) = try mounted(
            workspace: workspace, restoring: bench)

        let value = BenchSnapshot.project(
            writtenAt: Date(timeIntervalSince1970: 42),
            workspaces: workspaces,
            workbench: workbench,
            terminals: terminals,
            owners: []
        ) { _ in nil }

        let record = try XCTUnwrap(value.workspaces.first)
        XCTAssertEqual(record.state, .mounted)
        XCTAssertEqual(record.columns.map(\.id), bench.columns.map(\.id))
        XCTAssertEqual(record.columns[0].slots[0].panes.map(\.id), [first, hidden])
        XCTAssertFalse(record.columns[0].slots[0].panes[0].isVisible)
        XCTAssertTrue(record.columns[0].slots[0].panes[1].isVisible)
        XCTAssertFalse(record.columns[0].slots[0].panes[1].isFocused)
        XCTAssertTrue(record.columns[1].slots[0].panes[0].isVisible)
        XCTAssertTrue(record.columns[1].slots[0].panes[0].isFocused)
        XCTAssertEqual(record.columns[1].slots[0].panes[0].canvas?.source, .file("/tmp/plan.md"))
    }

    func testTerminalIdentityAndDirectPidMailboxOwnerAreReported() throws {
        let workspace = Workspace(path: "/tmp/bench-snapshot-owner")
        let (workspaces, workbench, terminals) = try mounted(workspace: workspace)
        let session = try XCTUnwrap(terminals.sessions.first)
        let owner = MailboxOwner(
            handle: "owner-1234", runtime: "codex", pid: 4242,
            sessionId: "session", cwd: workspace.path)

        let value = BenchSnapshot.project(
            writtenAt: .now,
            workspaces: workspaces,
            workbench: workbench,
            terminals: terminals,
            owners: [owner]
        ) { _ in 4242 }
        let terminal = try XCTUnwrap(value.workspaces[0].columns[0].slots[0].panes[0].terminal)

        XCTAssertEqual(terminal.sessionId, session.id)
        XCTAssertTrue(terminal.isLive)
        XCTAssertEqual(terminal.foregroundPid, 4242)
        XCTAssertEqual(terminal.owner?.handle, "owner-1234")
    }

    func testUnmatchedMailboxOwnerIsNotInvented() throws {
        let workspace = Workspace(path: "/tmp/bench-snapshot-unknown")
        let (workspaces, workbench, terminals) = try mounted(workspace: workspace)
        let unrelated = MailboxOwner(
            handle: "other", runtime: "claude", pid: 999,
            sessionId: nil, cwd: workspace.path)

        let value = BenchSnapshot.project(
            writtenAt: .now,
            workspaces: workspaces,
            workbench: workbench,
            terminals: terminals,
            owners: [unrelated]
        ) { _ in 4242 }

        XCTAssertNil(value.workspaces[0].columns[0].slots[0].panes[0].terminal?.owner)
    }

    func testParkedWorkspaceIsPersistedButNeverClaimsLiveVisibility() throws {
        let first = Workspace(path: "/tmp/bench-snapshot-live")
        let parked = Workspace(path: "/tmp/bench-snapshot-parked")
        let terminals = TerminalManager()
        let workbench = WorkbenchModel(terminals: terminals)
        let workspaces = WorkspaceModel(defaults: try defaults())

        workspaces.open(parked)
        let parkedBench = Workbench(
            panes: [Pane(content: .canvas(.url(URL(string: "https://example.com")!)))])
        workbench.activate(workspacePath: parked.path, restoring: parkedBench)
        workspaces.saveContext(terminalManager: terminals, workbench: workbench)

        workspaces.open(first)
        workbench.activate(workspacePath: first.path)
        let value = BenchSnapshot.project(
            writtenAt: .now,
            workspaces: workspaces,
            workbench: workbench,
            terminals: terminals,
            owners: []
        ) { _ in nil }

        let parkedRecord = try XCTUnwrap(value.workspaces.first { $0.path == parked.path })
        let pane = try XCTUnwrap(parkedRecord.columns.first?.slots.first?.panes.first)
        XCTAssertEqual(parkedRecord.state, .parked)
        XCTAssertTrue(pane.isSelected, "the persisted selection is still useful arrangement")
        XCTAssertFalse(pane.isVisible, "a parked selection is not on screen")
        XCTAssertFalse(pane.isFocused, "parked focusedSlot is only persisted arrangement")
    }

    func testSchemaAndIsoDateRoundTrip() throws {
        let original = BenchSnapshot(
            writtenAt: Date(timeIntervalSince1970: 1_700_000_000), workspaces: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(BenchSnapshot.self, from: encoder.encode(original))

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.format, BenchSnapshot.currentFormat)
        XCTAssertEqual(restored.version, BenchSnapshot.currentVersion)
    }
}
