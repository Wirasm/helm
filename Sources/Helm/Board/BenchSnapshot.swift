import Foundation

/// The agent-readable projection of helm's current bench.
///
/// This is reporting state, never restore state. `WorkspaceContext.workbench` remains the
/// persistence authority; a reader uses `writtenAt` to decide whether this file is fresh.
struct BenchSnapshot: Codable, Equatable {
    static let currentFormat = "helm.bench-snapshot"
    static let currentVersion = 1

    let format: String
    let version: Int
    let writtenAt: Date
    let workspaces: [WorkspaceRecord]

    init(writtenAt: Date, workspaces: [WorkspaceRecord]) {
        format = Self.currentFormat
        version = Self.currentVersion
        self.writtenAt = writtenAt
        self.workspaces = workspaces
    }

    @MainActor
    static func project(
        writtenAt: Date,
        workspaces: WorkspaceModel,
        workbench: WorkbenchModel,
        terminals: TerminalManager,
        owners: [MailboxOwner],
        foregroundPid: (TerminalSession) -> pid_t? = { $0.hostView.foregroundPid }
    ) -> BenchSnapshot {
        let mountedPath = workbench.workspacePath
        return BenchSnapshot(
            writtenAt: writtenAt,
            workspaces: workspaces.workspaces.map { workspace in
                let mounted = workspace.path == mountedPath
                let bench =
                    mounted
                    ? workbench.bench
                    : workspaces.contexts[workspace.path]?.workbench
                        ?? Workbench.migrating(
                            from: workspaces.contexts[workspace.path] ?? WorkspaceContext())
                return WorkspaceRecord(
                    workspace: workspace,
                    state: mounted ? .mounted : .parked,
                    bench: bench,
                    sessions: mounted ? terminals.sessions(for: workspace.path) : [],
                    owners: owners,
                    foregroundPid: foregroundPid)
            })
    }

    struct WorkspaceRecord: Codable, Equatable {
        enum State: String, Codable { case mounted, parked }

        let path: String
        let name: String
        let state: State
        let columns: [ColumnRecord]

        @MainActor
        init(
            workspace: Workspace,
            state: State,
            bench: Workbench?,
            sessions: [TerminalSession],
            owners: [MailboxOwner],
            foregroundPid: (TerminalSession) -> pid_t?
        ) {
            path = workspace.path
            name = workspace.name
            self.state = state
            let live = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            columns =
                bench?.columns.map { column in
                    ColumnRecord(
                        column: column,
                        focusedSlot: state == .mounted ? bench?.focusedSlot : nil,
                        live: live,
                        owners: owners,
                        foregroundPid: foregroundPid)
                } ?? []
        }
    }

    struct ColumnRecord: Codable, Equatable {
        let id: UUID
        let width: Double
        let slots: [SlotRecord]

        @MainActor
        init(
            column: Column,
            focusedSlot: Slot.ID?,
            live: [UUID: TerminalSession],
            owners: [MailboxOwner],
            foregroundPid: (TerminalSession) -> pid_t?
        ) {
            id = column.id
            width = column.width
            slots = column.slots.map { slot in
                SlotRecord(
                    slot: slot,
                    mounted: focusedSlot != nil,
                    focused: slot.id == focusedSlot,
                    live: live,
                    owners: owners,
                    foregroundPid: foregroundPid)
            }
        }
    }

    struct SlotRecord: Codable, Equatable {
        let id: UUID
        let height: Double
        let selectedPaneId: UUID
        let panes: [PaneRecord]

        @MainActor
        init(
            slot: Slot,
            mounted: Bool,
            focused: Bool,
            live: [UUID: TerminalSession],
            owners: [MailboxOwner],
            foregroundPid: (TerminalSession) -> pid_t?
        ) {
            id = slot.id
            height = slot.height
            selectedPaneId = slot.selected
            panes = slot.panes.map { pane in
                PaneRecord(
                    pane: pane,
                    selected: pane.id == slot.selected,
                    visible: mounted && pane.id == slot.selected,
                    focused: focused && pane.id == slot.selected,
                    live: live[pane.id],
                    owners: owners,
                    foregroundPid: foregroundPid)
            }
        }
    }

    struct PaneRecord: Codable, Equatable {
        enum Kind: String, Codable { case terminal, canvas }

        let id: UUID
        let kind: Kind
        let isSelected: Bool
        let isVisible: Bool
        let isFocused: Bool
        let terminal: TerminalRecord?
        let canvas: CanvasRecord?

        @MainActor
        init(
            pane: Pane,
            selected: Bool,
            visible: Bool,
            focused: Bool,
            live: TerminalSession?,
            owners: [MailboxOwner],
            foregroundPid: (TerminalSession) -> pid_t?
        ) {
            id = pane.id
            isSelected = selected
            isVisible = visible
            isFocused = focused
            switch pane.content {
            case .terminal:
                kind = .terminal
                terminal = TerminalRecord(
                    id: pane.id,
                    session: live,
                    owners: owners,
                    foregroundPid: foregroundPid)
                canvas = nil
            case let .canvas(source):
                kind = .canvas
                terminal = nil
                canvas = CanvasRecord(source: source)
            }
        }
    }

    struct TerminalRecord: Codable, Equatable {
        let sessionId: UUID
        let isLive: Bool
        let status: String?
        let failure: String?
        let title: String?
        let foregroundPid: pid_t?
        let owner: OwnerRecord?

        @MainActor
        init(
            id: UUID,
            session: TerminalSession?,
            owners: [MailboxOwner],
            foregroundPid: (TerminalSession) -> pid_t?
        ) {
            sessionId = id
            isLive = session != nil
            guard let session else {
                status = nil
                failure = nil
                title = nil
                self.foregroundPid = nil
                owner = nil
                return
            }
            switch session.status {
            case .starting:
                status = "starting"
                failure = nil
            case .running:
                status = "running"
                failure = nil
            case .exited:
                status = "exited"
                failure = nil
            case let .failed(issue):
                status = "failed"
                failure = issue
            }
            title = session.displayTitle
            let pid = foregroundPid(session)
            self.foregroundPid = pid
            owner = owners.first(where: { $0.pid == pid }).map(OwnerRecord.init)
        }
    }

    struct OwnerRecord: Codable, Equatable {
        let handle: String
        let runtime: String?
        let pid: pid_t
        let sessionId: String?
        let cwd: String?

        init(_ owner: MailboxOwner) {
            handle = owner.handle
            runtime = owner.runtime
            pid = owner.pid
            sessionId = owner.sessionId
            cwd = owner.cwd
        }
    }

    struct CanvasRecord: Codable, Equatable {
        let source: CanvasSource
    }
}
