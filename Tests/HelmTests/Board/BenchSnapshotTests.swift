import HelmWire
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
            handle: Handle(validating: "owner-1234")!, runtime: "codex", pid: 4242,
            sessionId: "session", cwd: workspace.path.value)

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
        XCTAssertEqual(terminal.owner?.handle.value, "owner-1234")
    }

    func testUnmatchedMailboxOwnerIsNotInvented() throws {
        let workspace = Workspace(path: "/tmp/bench-snapshot-unknown")
        let (workspaces, workbench, terminals) = try mounted(workspace: workspace)
        let unrelated = MailboxOwner(
            handle: Handle(validating: "other")!, runtime: "claude", pid: 999,
            sessionId: nil, cwd: workspace.path.value)

        let value = BenchSnapshot.project(
            writtenAt: .now,
            workspaces: workspaces,
            workbench: workbench,
            terminals: terminals,
            owners: [unrelated]
        ) { _ in 4242 }

        XCTAssertNil(value.workspaces[0].columns[0].slots[0].panes[0].terminal?.owner)
    }

    func testParkedWorkspaceKeepsLiveTerminalIdentityButNeverClaimsVisibility() throws {
        let first = Workspace(path: "/tmp/bench-snapshot-live")
        let parked = Workspace(path: "/tmp/bench-snapshot-parked")
        let terminals = TerminalManager()
        let workbench = WorkbenchModel(terminals: terminals)
        let workspaces = WorkspaceModel(defaults: try defaults())

        workspaces.open(parked)
        workbench.activate(workspacePath: parked.path)
        let parkedTerminal = try XCTUnwrap(terminals.sessions(for: parked.path).first)
        workspaces.saveContext(terminalManager: terminals, workbench: workbench)

        workspaces.open(first)
        workbench.activate(workspacePath: first.path)
        let value = BenchSnapshot.project(
            writtenAt: .now,
            workspaces: workspaces,
            workbench: workbench,
            terminals: terminals,
            owners: [
                MailboxOwner(
                    handle: Handle(validating: "parked-agent")!, runtime: "codex", pid: 4242,
                    sessionId: "session", cwd: parked.path.value)
            ]
        ) { session in session.id == parkedTerminal.id ? 4242 : nil }

        let parkedRecord = try XCTUnwrap(value.workspaces.first { $0.path == parked.path })
        let pane = try XCTUnwrap(parkedRecord.columns.first?.slots.first?.panes.first)
        XCTAssertEqual(parkedRecord.state, .parked)
        XCTAssertTrue(pane.isSelected, "the persisted selection is still useful arrangement")
        XCTAssertFalse(pane.isVisible, "a parked selection is not on screen")
        XCTAssertFalse(pane.isFocused, "parked focusedSlot is only persisted arrangement")
        XCTAssertTrue(pane.terminal?.isLive == true)
        XCTAssertEqual(pane.terminal?.sessionId, parkedTerminal.id)
        XCTAssertEqual(pane.terminal?.owner?.handle.value, "parked-agent")
    }

    /// The gate everything else in `project` is decided by: `workspace.path == mountedPath`.
    /// #227 — `testParkedWorkspaceKeepsLiveTerminalIdentityButNeverClaimsVisibility` above
    /// pins one workspace's own record; this pins the JOIN across two, which is what the
    /// gate actually routes. A snapshot scoped to the mounted workspace has to carry its own
    /// terminal and must not carry a parked workspace's — and the reverse for the parked
    /// workspace's own record.
    func testMountedWorkspaceShowsItsOwnTerminalAndExcludesAParkedWorkspaces() throws {
        let parked = Workspace(path: "/tmp/bench-snapshot-routing-parked")
        let live = Workspace(path: "/tmp/bench-snapshot-routing-live")
        let terminals = TerminalManager()
        let workbench = WorkbenchModel(terminals: terminals)
        let workspaces = WorkspaceModel(defaults: try defaults())

        workspaces.open(parked)
        workbench.activate(workspacePath: parked.path)
        let parkedTerminal = try XCTUnwrap(terminals.sessions(for: parked.path).first)
        workspaces.saveContext(terminalManager: terminals, workbench: workbench)

        workspaces.open(live)
        workbench.activate(workspacePath: live.path)
        let liveTerminal = try XCTUnwrap(terminals.sessions(for: live.path).first)

        let value = BenchSnapshot.project(
            writtenAt: .now, workspaces: workspaces, workbench: workbench, terminals: terminals,
            owners: []
        ) { _ in nil }

        func paneIDs(_ record: BenchSnapshot.WorkspaceRecord) -> [UUID] {
            record.columns.flatMap { $0.slots.flatMap { $0.panes.map(\.id) } }
        }

        let liveRecord = try XCTUnwrap(value.workspaces.first { $0.path == live.path })
        XCTAssertTrue(
            paneIDs(liveRecord).contains(liveTerminal.id),
            "the mounted workspace's snapshot has to carry its own terminal")
        XCTAssertFalse(
            paneIDs(liveRecord).contains(parkedTerminal.id),
            "…and must not carry a parked workspace's")

        let parkedRecord = try XCTUnwrap(value.workspaces.first { $0.path == parked.path })
        XCTAssertTrue(
            paneIDs(parkedRecord).contains(parkedTerminal.id),
            "a parked workspace still has to report its own terminal identity")
        XCTAssertFalse(
            paneIDs(parkedRecord).contains(liveTerminal.id),
            "…and must not pick up the mounted workspace's pane ids")
    }

    /// The acceptance criterion #223 names explicitly: `WorkspaceRecord.path` is read by
    /// agents outside the process, so `WorkspacePath` must not change its wire shape.
    /// Inspected as `Any` off `JSONSerialization` rather than compared against a whole JSON
    /// string, so this fails loudly if `path` ever becomes an object (`{"value":"…"}`)
    /// instead of staying the bare string a `WorkspacePath(_ url:)` reader still expects.
    func testWorkspaceRecordPathEncodesAsABareStringUnchangedByWorkspacePath() throws {
        let workspace = Workspace(path: "/tmp/bench-snapshot-json-path")
        let (workspaces, workbench, terminals) = try mounted(workspace: workspace)

        let snapshot = BenchSnapshot.project(
            writtenAt: .now, workspaces: workspaces, workbench: workbench, terminals: terminals,
            owners: []
        ) { _ in nil }

        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        let path = try XCTUnwrap(records.first?["path"])

        XCTAssertTrue(
            path is String,
            "WorkspacePath encodes through a single-value container, so this must still be a "
                + "bare string — an object here breaks every agent reading helm.bench-snapshot")
        XCTAssertEqual(path as? String, workspace.path.value)
    }

    /// #233's acceptance criterion, and the same obligation one field over: `OwnerRecord.handle`
    /// became a `Handle`, and an agent reading `snapshot.json` must not be able to tell.
    ///
    /// **This one has to pass on both sides of the change, and that is what it is for.** A test
    /// that only goes green after the refactor would prove the refactor happened; this proves it
    /// did not overshoot, so it is a control against a `Handle` that encodes through a keyed
    /// container (`{"value":"…"}`) — which is what a hand-written `Codable` conformance, or a
    /// later field added to `Handle`, would silently produce. Verified by giving `Handle` a keyed
    /// encoder: this fails on the `handle is String` assertion below.
    ///
    /// Read off `JSONSerialization` rather than by a Swift round trip for the reason
    /// `testWorkspaceRecordPathEncodesAsABareStringUnchangedByWorkspacePath` above does — a round
    /// trip decodes with the same type it encoded with and passes either way, so it measures
    /// nothing here. `format` and `version` are checked against the same bytes: the shape did not
    /// change, so neither may they.
    func testOwnerRecordHandleEncodesAsABareStringUnchangedByHandle() throws {
        let workspace = Workspace(path: "/tmp/bench-snapshot-json-handle")
        let (workspaces, workbench, terminals) = try mounted(workspace: workspace)
        let owner = MailboxOwner(
            handle: Handle(validating: "owner-1234")!, runtime: "codex", pid: 4242,
            sessionId: "session", cwd: workspace.path.value)

        let snapshot = BenchSnapshot.project(
            writtenAt: .now, workspaces: workspaces, workbench: workbench, terminals: terminals,
            owners: [owner]
        ) { _ in 4242 }

        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, BenchSnapshot.currentFormat)
        XCTAssertEqual(json["version"] as? Int, BenchSnapshot.currentVersion)

        let records = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        let columns = try XCTUnwrap(records.first?["columns"] as? [[String: Any]])
        let slots = try XCTUnwrap(columns.first?["slots"] as? [[String: Any]])
        let panes = try XCTUnwrap(slots.first?["panes"] as? [[String: Any]])
        let terminal = try XCTUnwrap(panes.first?["terminal"] as? [String: Any])
        let record = try XCTUnwrap(terminal["owner"] as? [String: Any])
        let handle = try XCTUnwrap(record["handle"])

        XCTAssertTrue(
            handle is String,
            "Handle encodes through a single-value container, so this must still be a bare "
                + "string — an object here breaks every agent reading helm.bench-snapshot")
        XCTAssertEqual(handle as? String, "owner-1234")
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
