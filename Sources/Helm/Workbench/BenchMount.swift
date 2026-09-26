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

// MARK: - MountState

/// What the workbench is doing right now: nothing, asking, or showing a bench.
///
/// **One field rather than a nil `bench` paired with a non-nil `restoreOffer`.** That pairing
/// was the first draft, and it was an invariant carried by a comment restated in three files —
/// `WorkbenchModel` explaining which nil is which, `WorkbenchView` branching on the offer to
/// tell an unanswered mount from an empty helm, `WorkbenchSpoolCommander` doing the same to
/// pick a refusal. Six writers inside one file had to set both by hand, together, because the
/// author remembered to; nothing stopped a seventh setting one. `AGENTS.md`'s rule is exact and
/// says to apply it *before* the defect is reachable: **prefer a newtype the day the comment
/// gets written, not the day it is disbelieved.**
///
/// `bench` and `restoreOffer` survive as computed readers over this, so every consumer outside
/// the model reads exactly what it read before — the change is that no combination of them can
/// be constructed that this enum does not name.
enum MountState: Equatable {
    /// No workspace open. A fresh install, and where closing the last workspace returns to.
    case empty
    /// A workspace is on screen and waiting on the operator to answer #85's question. **Nothing
    /// is drawn and no pty is spawned in this state**: the bench is benchd's, unchanged, until
    /// the answer goes back as a verb.
    case awaitingRestore(BenchRestoreOffer)
    /// A bench, on screen. Never empty — `Workbench`'s first invariant is that it holds a pane.
    case mounted(Workbench)

    var bench: Workbench? {
        if case let .mounted(bench) = self { bench } else { nil }
    }

    var restoreOffer: BenchRestoreOffer? {
        if case let .awaitingRestore(offer) = self { offer } else { nil }
    }
}

// MARK: - BenchMountPolicy

/// Whether a workspace's bench is worth asking about the first time it is shown this launch, and
/// which bench the question is about (#85).
///
/// **Pure, and that is the acceptance criterion**: *"the decision logic is reachable from
/// `swift test` — not trapped in a `View`. Three defects in two days came from logic living
/// in a view."* The question stays helm's while restored terminals come back as empty shells
/// (plan D4 of #354); `BenchDrawing` asks it, and the answer goes to benchd as a verb.
///
/// A spool spawn never waits behind it: #179's rule is exact — *a question nobody will be there
/// to answer must be answered in advance, and answered so the agent can work* — so a spawn
/// answers it by restoring (`WorkbenchModel.mountWithoutAsking`).
enum BenchMountPolicy {
    /// nil when there is nothing to decide.
    ///
    /// - Parameters:
    ///   - bench: the workspace's bench, as benchd holds it.
    ///   - shelved: a bench a previous *fresh* declined. Kept because *"one wrong click should
    ///     not destroy a layout: fresh means do not open it now, never forget it."*
    static func offer(bench: Workbench, shelved: Workbench?) -> BenchRestoreOffer? {
        let candidate = candidate(bench: bench, shelved: shelved)
        // Restoring one empty shell and building one empty shell differ only in a uuid the
        // operator cannot see, so asking would be chrome with no decision under it.
        guard !candidate.isOneEmptyShell else { return nil }
        return BenchRestoreOffer(bench: candidate)
    }

    /// Which bench the question is about.
    ///
    /// The bench, normally. The **shelved** one when the bench is a single empty shell — which
    /// is precisely the "you chose fresh, did nothing with it, and relaunched" case, and the one
    /// moment a declined bench is most worth offering back. It stops offering itself as soon as
    /// the operator builds a bench worth keeping, so a decline does not turn into a nag.
    private static func candidate(bench: Workbench, shelved: Workbench?) -> Workbench {
        guard bench.isOneEmptyShell, let shelved else { return bench }
        return shelved
    }
}
