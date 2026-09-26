import Foundation
import HelmWire

// The document benchd sends and the values helm renders, converted in both directions: from the
// document when a frame arrives, and to it once, for the import of helm's saved benches.

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

extension BenchDocument.Bench {
    /// A helm bench as the document spells it, for the import. A placeholder pane cannot reach
    /// here — only a document makes one, and the import runs only into an empty document.
    init(_ bench: Workbench) {
        self.init(
            columns: bench.columns.map { column in
                BenchDocument.Column(
                    id: column.id,
                    slots: column.slots.map { slot in
                        BenchDocument.Slot(
                            id: slot.id,
                            panes: slot.panes.compactMap { pane in
                                Surface(pane.content).map {
                                    BenchDocument.Pane(id: pane.id, surface: $0, name: pane.name)
                                }
                            },
                            selected: slot.selected, height: slot.height)
                    },
                    width: column.width)
            },
            focusedSlot: bench.focusedSlot)
    }
}

extension Pane.Content {
    init(_ surface: Surface) {
        switch surface {
        case let .terminal(agent): self = .terminal(agent: agent.map(ResumableAgent.init))
        case let .canvas(path): self = .canvas(.file(path))
        case .browser: self = .browser
        case let .unsupported(kind): self = .unsupported(kind)
        }
    }
}

extension Surface {
    /// nil for a placeholder, which is benchd's pane and not helm's to write back.
    init?(_ content: Pane.Content) {
        switch content {
        case let .terminal(agent): self = .terminal(agent: agent.map(BenchDocument.Agent.init))
        case let .canvas(source): self = .canvas(path: source.fileURL.path)
        case .browser: self = .browser
        case .unsupported: return nil
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
    /// Every pane id in the document — each workspace's bench and shelf, and every drawer (#356):
    /// what helm may keep a live object for. A pane in none of them has been closed; a pane moved
    /// into a drawer has not, and keeps its object.
    var paneIDs: Set<UUID> {
        let benches = workspaces.flatMap { workspace in
            ([workspace.bench] + (workspace.shelved.map { [$0] } ?? []))
                .flatMap(\.columns).flatMap(\.slots).flatMap(\.panes).map(\.id)
        }
        return Set(benches + drawers.flatMap(\.panes).map(\.id))
    }

    /// Every pane id on a workspace's bench or shelf — the panes helm has seen arrive. A terminal
    /// in a drawer (#356) is not among them: it has no workspace to start in and helm draws no
    /// drawers yet, so when it is moved onto a bench it arrives there, and starts.
    var workspacePaneIDs: Set<UUID> {
        Set(
            workspaces.flatMap { workspace in
                ([workspace.bench] + (workspace.shelved.map { [$0] } ?? []))
                    .flatMap(\.columns).flatMap(\.slots).flatMap(\.panes).map(\.id)
            })
    }

    /// The terminals on each workspace's bench that are not in `known`: what arrived since the
    /// document those ids came from, to be started where they landed.
    func terminals(arrivedSince known: Set<UUID>) -> [(WorkspacePath, [UUID])] {
        workspaces.compactMap { workspace in
            let arrived = workspace.bench.columns.flatMap(\.slots).flatMap(\.panes)
                .filter { !known.contains($0.id) }
                .filter { if case .terminal = $0.surface { true } else { false } }
                .map(\.id)
            return arrived.isEmpty ? nil : (WorkspacePath(workspace.path), arrived)
        }
    }

    func workspace(at path: WorkspacePath) -> Workspace? {
        workspaces.first { WorkspacePath($0.path) == path }
    }
}
