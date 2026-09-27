import Foundation

/// One node of a run as the drawer draws it: a dot in the run's row (#382).
struct ArchonStage: Equatable, Sendable, Identifiable {
    enum State: Equatable, Sendable {
        /// Not reached yet.
        case pending
        case running
        /// The node a paused run stopped at: a gate, or a durable wait.
        case paused
        case completed
        case failed
        case skipped
    }

    let id: String
    let state: State
    let durationMs: Int?
    let error: String?
}

extension ArchonRun {
    /// The run's stages in workflow order, or nil when there is nothing to draw them from.
    ///
    /// **The order and the full list are Archon's `terminal_graph`**, which it writes before the
    /// first node runs, so a stage not reached yet is still a dot. **The state is the fold of its
    /// events**, which `nodes` carries: from `workflow status --verbose` for a live run, and on
    /// every run once `workflow runs --verbose` exists (Archon PR A1). Pass the nodes a separate
    /// call answered as `nodes`; the run's own win when it has them.
    ///
    /// **A finished run whose nodes nobody asked for has no stages**, rather than a row of
    /// guessed dots: `completed` does not mean every node ran (some are skipped), and `failed`
    /// does not say where. The drawer shows its outcome instead. Nodes Archon ran that are not in
    /// the graph (a loop's body, `candidates.step`) are inside a stage and get no dot of their own.
    func stages(nodes supplied: [ArchonNode]? = nil) -> [ArchonStage]? {
        guard let ids = metadata?.terminalGraph?.nodeIds, !ids.isEmpty else { return nil }
        let folded = (nodes.flatMap { $0.isEmpty ? nil : $0 }) ?? supplied
        if folded == nil, isFinished { return nil }
        let byID = Dictionary(
            (folded ?? []).map { ($0.nodeId, $0) }, uniquingKeysWith: { _, last in last })
        let active = Set(activeNodes ?? [])
        return ids.map { id in
            let node = byID[id]
            return ArchonStage(
                id: id, state: state(of: id, node: node, active: active),
                durationMs: node?.durationMs, error: node?.error)
        }
    }

    private func state(of id: String, node: ArchonNode?, active: Set<String>) -> ArchonStage.State {
        let isHere = active.contains(id) || node?.state == .running
        if isHere { return isPaused ? .paused : .running }
        switch node?.state {
        case .completed?: return .completed
        case .failed?: return .failed
        case .skipped?: return .skipped
        case .running?, .unknown?, nil: return .pending
        }
    }

    /// The stage a live run is on, by name: the first active node, else the last one that started.
    var currentStage: String? {
        activeNodes?.first ?? currentNode?.nodeId
    }
}
