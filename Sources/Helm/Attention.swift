import Foundation

/// Everything helm computes that the engine does not state.
///
/// This file exists to keep a boundary visible. `KildWire.swift` is what the engine said;
/// this is what helm worked out. Any value produced here must be labelled as derived
/// wherever it is rendered — most importantly on the land gate, where a computed line sits
/// among reported ones and a reader has no other way to tell them apart.
///
/// Both derivations here are pure functions of wire values, which is what makes them
/// testable without a running engine.

// MARK: - Attention

/// The attention model, in one field.
///
/// `idle` is set by the engine when an agent's turn ends — for an owned agent on
/// `agent_end`, for an attached one on an empty drain. It observes the *process*, so it
/// catches an agent that hit a wall and stopped as surely as one that finished politely.
/// Its predecessor only fired when an agent remembered to follow a reporting convention,
/// and stayed silent in exactly the case you most needed telling about.
///
/// What it cannot do is say *why*. "Finished the task" and "blocked on a question" are both
/// `idle`, and separating them means reading the message, which is interpretation and
/// belongs to PRP. That is an acceptable loss here because both genuinely want you — one to
/// review, one to answer. **"Waiting on you" is true of each**, so the count does not need
/// to know which.
enum Attention {
    /// Agents that have stopped and are waiting for a human.
    ///
    /// A `stopped` agent is excluded: its process is gone, so it is not waiting on anyone.
    /// Idle means resting between turns; stopped means over. Counting the latter would
    /// inflate the badge with agents nobody can unblock.
    static func waiting(in kilds: [Kild]) -> [(kild: Kild, agent: Agent)] {
        kilds.flatMap { kild in
            kild.agents
                .filter { $0.isIdle && !$0.isStopped }
                .map { (kild: kild, agent: $0) }
        }
    }

    /// How many agents are waiting on you, across every kild.
    ///
    /// This is the number the workspace bar shows, and it answers the question
    /// `docs/escalation.md` makes a hard requirement: *"If helm cannot answer 'how many
    /// agents are blocked on me right now?' at a glance, the mechanism is not finished. A
    /// list is not enough."* Dots on rows are a list — they only tell you where attention is
    /// once you are already looking at the sidebar.
    ///
    /// Zero is rendered as *absence*, never as `0`. A zero permanently on screen becomes
    /// furniture, and furniture is not loud.
    static func waitingCount(in kilds: [Kild]) -> Int {
        waiting(in: kilds).count
    }
}

// MARK: - Collisions

/// Two live kilds that have both changed the same file.
///
/// Derived, never served: no single kild can know this, because it is a fact *between*
/// kilds. The engine gives `changedFiles` per kild and helm intersects them.
struct Collision: Sendable, Equatable {
    /// The other kild involved. Collisions are symmetric, so each side sees the other.
    let other: Kild.ID
    let otherName: String
    /// The paths both kilds touched, sorted for a stable rendering.
    let files: [String]
}

extension Attention {
    /// Intersect `changedFiles` across live kilds to find which of them are working on the
    /// same paths.
    ///
    /// **This is the `collidesWith` that is not on the wire.** An earlier draft of the API
    /// review claimed `/api/kilds/status` would serve it; it does not, and no route ever
    /// did. What the engine serves is the `changedFiles[]` that makes the derivation
    /// possible, which is the correct division: the engine reports what each kild did, and
    /// the client — which is the only thing looking at every kild at once — works out what
    /// that means collectively.
    ///
    /// Orphans are excluded: they have no record, no `changedFiles`, and no agents that
    /// could be working. A kild never collides with itself.
    static func collisions(among kilds: [Kild]) -> [Kild.ID: [Collision]] {
        let live = kilds.filter { !$0.isOrphan }
        let changed: [(kild: Kild, files: Set<String>)] = live.compactMap { kild in
            guard let files = kild.git?.changedFiles, !files.isEmpty else { return nil }
            return (kild: kild, files: Set(files))
        }

        var result: [Kild.ID: [Collision]] = [:]
        for (index, lhs) in changed.enumerated() {
            for rhs in changed[(index + 1)...] {
                let shared = lhs.files.intersection(rhs.files)
                guard !shared.isEmpty else { continue }
                let files = shared.sorted()
                result[lhs.kild.id, default: []]
                    .append(Collision(other: rhs.kild.id, otherName: rhs.kild.name, files: files))
                result[rhs.kild.id, default: []]
                    .append(Collision(other: lhs.kild.id, otherName: lhs.kild.name, files: files))
            }
        }
        return result
    }
}

// MARK: - Grouping

/// How the observe column divides kilds.
///
/// rev 5 drew one tree rooted at the operator's checkout. The engine records no parent
/// edge, so that structure is not buildable yet (see `Kild`) — but the *grouping* it
/// depended on is, and it carries most of the value: abandoned kilds get a home and stop
/// being invisible.
enum KildGroup: Sendable, Equatable {
    /// Kilds with a record and at least one agent — the ones being worked in.
    case live
    /// Kilds that exist only as worktrees on disk, their records gone.
    ///
    /// 116 of these existed on the machine running the engine while the cockpit showed
    /// none, and `prune` reclaimed zero of them, because prune only removes trees whose
    /// branch already merged. Abandoned work was structurally permanent *and* invisible.
    case orphaned
}

extension Attention {
    /// Split kilds into the groups the observe column renders, each sorted for stability.
    ///
    /// Live kilds sort attention-first: any kild with a waiting agent rises, so the thing
    /// asking for you is never below the fold. Orphans sort by name, since they have no
    /// activity to sort by — no agents, no log, no git record.
    static func grouped(_ kilds: [Kild]) -> [KildGroup: [Kild]] {
        let waitingIDs = Set(waiting(in: kilds).map(\.kild.id))
        let live = kilds.filter { !$0.isOrphan }.sorted {
            let (l, r) = (waitingIDs.contains($0.id), waitingIDs.contains($1.id))
            return l == r ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : l
        }
        let orphaned = kilds.filter(\.isOrphan).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return [.live: live, .orphaned: orphaned]
    }
}
