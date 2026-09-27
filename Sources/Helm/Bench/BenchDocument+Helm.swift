import Foundation
import HelmWire

// The document benchd sends, converted to the values helm renders when a frame arrives.

extension Workbench {
    /// The bench a workspace of benchd's document describes. nil when it holds no pane, which a
    /// document written by benchd never does.
    init?(document bench: BenchDocument.Bench) {
        let columns = bench.columns.map { column in
            Column(
                id: column.id,
                slots: column.slots.map { slot in
                    Slot(
                        id: slot.id,
                        panes: slot.panes.map {
                            Pane(id: $0.id, content: .init($0.surface), name: $0.name)
                        },
                        selected: slot.selected, height: slot.height)
                },
                width: column.width)
        }
        guard let built = Workbench.assembled(columns: columns, focusedSlot: bench.focusedSlot)
        else { return nil }
        self = built
    }
}

extension Pane.Content {
    init(_ surface: Surface) {
        switch surface {
        // A pane showing a benchd session holds that agent, running: there is nothing to resume
        // and nothing for #85 to ask about. Its record matters only once the session is gone,
        // and benchd clears `session` then (a restart), which is when the offer appears.
        case let .terminal(agent, session, _):
            self = .terminal(agent: session == nil ? agent.map(ResumableAgent.init) : nil)
        case let .canvas(path): self = .canvas(.file(path))
        case .browser: self = .browser
        case .sessions: self = .sessions
        case .archon: self = .archon
        case .worktrees: self = .worktrees
        case let .unsupported(kind): self = .unsupported(kind)
        }
    }
}

extension ResumableAgent {
    init(_ agent: BenchDocument.Agent) {
        self.init(command: agent.command, session: agent.session, cwd: agent.cwd)
    }
}

extension BenchDocument.Agent {
    init(_ agent: ResumableAgent) {
        self.init(command: agent.command, session: agent.session, cwd: agent.cwd)
    }
}

extension BenchDocument {
    /// Every pane id in the document — each workspace's bench, and every drawer (#356):
    /// what helm may keep a live object for. A pane in none of them has been closed; a pane moved
    /// into a drawer has not, and keeps its object.
    var paneIDs: Set<UUID> {
        let benches = workspaces.flatMap(\.bench.columns).flatMap(\.slots).flatMap(\.panes)
            .map(\.id)
        return Set(benches + drawers.flatMap(\.panes).map(\.id))
    }

    /// The drawer a pane is in, if it is in one.
    func drawer(holding pane: UUID) -> Drawer? {
        drawers.first { $0.panes.contains { $0.id == pane } }
    }

    /// What a pane shows, wherever it lives: a workspace's live bench or a drawer.
    func surface(of pane: UUID) -> Surface? {
        let panes =
            workspaces.flatMap { $0.bench.columns.flatMap(\.slots).flatMap(\.panes) }
            + drawers.flatMap(\.panes)
        return panes.first { $0.id == pane }?.surface
    }

    func workspace(at path: WorkspacePath) -> Workspace? {
        workspaces.first { WorkspacePath($0.path) == path }
    }
}
