import Foundation

// MARK: - BenchRestoreOffer

/// The question a workspace asks when it is mounted: this is what you left here — put it
/// back, or start fresh? (#85)
///
/// **The pane count is the most valuable part of it**, and it is why this is a value with
/// counts on it rather than a bare `Workbench`. A bench that reopens silently grows without
/// anyone noticing — the live domain held 17 persisted terminal ids against 2 live shells
/// when #85 was written. Naming the count at mount turns that from a hazard into an
/// annoyance the operator can decline, which is the whole of the ticket.
struct BenchRestoreOffer: Equatable {
    /// Exactly what `restore` would mount. Carried whole rather than described, so answering
    /// needs no second lookup and cannot mount a different bench from the one it counted.
    let bench: Workbench

    var paneCount: Int { bench.panes.count }
    var terminalCount: Int { bench.terminalPaneIDs.count }
    var canvasCount: Int { bench.canvasPanes.count }
    /// How many of those panes had an agent running in them. #63's offer is made *after* the
    /// bench is restored — a pane has to exist before an agent can be offered for it — so
    /// this is a count and not a choice: it tells the operator what declining costs.
    var agentCount: Int { bench.resumableAgents.count }
}

/// What the operator said.
enum BenchRestoreChoice: Equatable {
    case restore
    case fresh
}

// MARK: - BenchMount

/// What helm does with a workspace's saved bench at the moment it is mounted.
enum BenchMount: Equatable {
    /// `WorkbenchModel.defaultBench` — one shell. Also the never-visited case.
    case fresh
    /// Put this bench back with no question. Either there is nothing worth asking about, or
    /// the question was already answered this launch.
    case restore(Workbench)
    /// Stop, and ask. **Nothing is mounted and nothing is spawned while this is the state** —
    /// which is also what keeps the saved bench intact, because `WorkspaceModel.saveContext`
    /// returns early on a nil bench and therefore writes nothing over it.
    case ask(BenchRestoreOffer)
}

/// When a mount asks, and which bench it asks about (#85).
///
/// **Pure, and that is the acceptance criterion**: *"the decision logic is reachable from
/// `swift test` — not trapped in a `View`. Three defects in two days came from logic living
/// in a view."*
///
/// **Only the operator's own mount reaches here at all**, which is
/// `WorkbenchModel.activate(workspacePath:offering:shelved:)` — the twin of
/// `activate(workspacePath:restoring:)`, which mounts what it is given and asks nobody. That
/// pair is `Workbench.splitRight(with:)`/`splitRight(offering:)` one level up, and it exists
/// because the first draft of #85 had only one door: a spool spawn's `cwd` becomes a workspace
/// (`WorkbenchSpoolSpawner.openTerminal`), so a saved bench on that folder would have raised a
/// question with **nobody at the pane to answer it**, and the spawn would then have failed
/// against a bench that was never built. That is #179's silent hang reached through a
/// different door, and #179's rule is exact: *a question nobody will be there to answer must
/// be answered in advance, and answered so the agent can work.*
enum BenchMountPolicy {
    /// - Parameters:
    ///   - saved: `WorkspaceContext.workbench` — the bench this workspace was last left in.
    ///   - shelved: `WorkspaceContext.shelvedBench` — a bench a previous *fresh* declined.
    ///     Kept because *"one wrong click should not destroy a layout: fresh means do not open
    ///     it now, never forget it."*
    ///   - answered: whether this workspace's question has already been answered **in this
    ///     process**. A workspace switch re-mounts, and re-asking on every switch would make
    ///     the question chrome rather than a decision. Once per launch per workspace is what
    ///     #85 means by *"per-workspace, at mount"*.
    static func mount(saved: Workbench?, shelved: Workbench? = nil, answered: Bool) -> BenchMount {
        guard !answered else { return saved.map(BenchMount.restore) ?? .fresh }
        guard let candidate = candidate(saved: saved, shelved: shelved) else { return .fresh }
        // Restoring one empty shell and building one empty shell differ only in a uuid the
        // operator cannot see, so asking would be chrome with no decision under it. Restore
        // rather than fresh, because the uuid is not nothing: it is what `TerminalManager`
        // rebuilds the row under, and what a later launch's agent record hangs off.
        guard !candidate.isOneEmptyShell else { return .restore(candidate) }
        return .ask(BenchRestoreOffer(bench: candidate))
    }

    /// Which bench the question is about.
    ///
    /// The saved one, normally. The **shelved** one when what was saved is a single empty
    /// shell — which is precisely the "you chose fresh, did nothing with it, and relaunched"
    /// case, and the one moment a declined bench is most worth offering back. It stops
    /// offering itself as soon as the operator builds a bench worth saving, so a decline does
    /// not turn into a nag: the saved bench is then no longer one empty shell and it is what
    /// the question is about.
    private static func candidate(saved: Workbench?, shelved: Workbench?) -> Workbench? {
        guard let saved else { return shelved }
        guard saved.isOneEmptyShell, let shelved else { return saved }
        return shelved
    }
}
