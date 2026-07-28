import Foundation

/// The kild engine's REST payloads, mirrored exactly.
///
/// One rule governs this file: **a type here is what the engine sends, nothing more.**
/// No renames, no convenience aliases, no defaults that invent a value the engine did not
/// state. When the wire calls it `handle`, so do we. The moment a field is translated on
/// the way in, two vocabularies exist for one fact and every later reader has to know both.
///
/// Everything *derived* from these values lives in `Attention.swift` and is named as a
/// derivation, so a reader can always tell server truth from something helm computed.
/// That distinction matters most on the land gate, where a derived line sits beside
/// reported ones and would otherwise be indistinguishable.
///
/// Optionality is copied from the engine's own types rather than guessed. A field that is
/// `?` here is one the engine may genuinely omit — usually because older persisted records
/// predate it.

// MARK: - Agents

/// Which side of the boundary an agent lives on. The engine's only axis for an agent, and
/// the one field helm switches on — it decides how much is observable, not what an agent is.
///
/// Always present on the wire: the engine resolves an absent value to `owned` at the
/// serialisation boundary, so clients never have to. (It did not always — an archive
/// written before the field existed once served agents with no ownership at all.)
enum Ownership: String, Codable, Sendable, Equatable {
    /// kild spawned the process and talks to it over its stdio, so it sees everything:
    /// tool calls, prose deltas, token and cost stats.
    case owned
    /// An external harness kild addresses but never spawned. The engine can only report
    /// the messages it routed itself — sparse by construction, not by choice.
    case attached
}

/// An agent on a kild's roster.
///
/// This is the *identity* shape, carried by the cheap listing. `tokens`, `cost`,
/// `piSessionId` and `piSessionFile` arrive only on the costly `/status` call, which is why
/// they are optional here rather than split into a second type: one type that is sometimes
/// fuller reads better than two that differ by four fields.
struct Agent: Codable, Sendable, Equatable, Identifiable {
    /// How the agent is addressed. Unique within its kild, which makes it the identity.
    let handle: String
    let ownership: Ownership
    /// Opaque to helm. The engine stores it and never interprets it, so neither do we:
    /// rendered as text, never styled by value, never sorted by, never given an icon.
    /// The moment a persona means something here, PRP has leaked into the cockpit.
    var persona: String?
    var model: String?
    /// The handle of the agent that spawned this one — absent for the creator's initial
    /// roster. A ground-truth spawn edge, so the roster can be drawn as the tree it is
    /// rather than inferred from prose in the log.
    var invitedBy: String?
    /// Set by the engine when an owned agent ends its turn, or when an attached agent
    /// drains an empty inbox; cleared when work arrives. This one field is the whole
    /// attention model — see `Attention.swift`.
    var idle: Bool?
    /// The agent's process is gone. Distinct from `idle`: idle is resting, stopped is over.
    var stopped: Bool?
    var tokens: Int?
    var cost: Double?
    /// pi's own session identifier, and the absolute path to its session file. Present for
    /// owned agents once the session reports itself; an attached agent has neither, because
    /// kild never spawned it and there is nothing to resume.
    var piSessionId: String?
    var piSessionFile: String?

    var id: String { handle }

    /// `idle` is optional on the wire but boolean in meaning — absent means "not idle".
    /// Callers should read this rather than unwrapping, so the absent case is handled once.
    var isIdle: Bool { idle == true }
    var isStopped: Bool { stopped == true }
}

// MARK: - Git

/// A kild's git position, from the costly half of the listing.
///
/// Every field is optional because the whole object is: an orphan kild has no record to
/// measure against, and `/api/kilds` (the cheap call) omits git entirely.
struct GitStatus: Codable, Sendable, Equatable {
    var path: String?
    var branch: String?
    var base: String?
    var ahead: Int?
    var behind: Int?
    var dirty: Bool?
    /// A **count**, not a list — the engine sends an integer here. Named as the wire names
    /// it despite the plural reading like a collection.
    var uncommittedFiles: Int?
    /// Paths changed relative to base. The input to collision derivation: two kilds that
    /// both touch a path are in conflict with each other, which no single kild can know.
    var changedFiles: [String]?
    var conflictsWithBase: Bool?
}

struct CostTotals: Codable, Sendable, Equatable {
    var tokens: Int
    var cost: Double
}

/// What a land carried, counted at the moment it merged.
struct LandedSummary: Codable, Sendable, Equatable {
    var commits: Int
    var files: Int
}

// MARK: - Kilds

/// A kild: a git worktree and the agents working in it.
///
/// One type serves both halves of the split listing. `GET /api/kilds` fills identity, tree
/// edges and agents; `GET /api/kilds/status` adds `git` and `totals` on its own cadence.
/// The split exists because computing git status for every kild on every poll forced a slow
/// cadence onto a query that is mostly identity.
///
/// **There is no `parent`.** rev 5 drew the observe column as one tree rooted at the
/// operator's checkout, built from a parent edge — but the engine records none.
/// `POST /api/kilds` accepts `from` and validates it, then discards it: no field on the
/// persisted kild holds it. Nor can it be derived, since a forked kild's `base` names a
/// branch, not the kild it forked from. Until the engine keeps that edge, the column is
/// flat with groups. See `QUESTIONS.md`.
struct Kild: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    /// The project directory its agents run in — the repo an orphan tree belongs to.
    let cwd: String
    /// The `kild/<worktree>` branch name minus the prefix. Absent for a kild that runs in
    /// the checkout itself rather than a worktree of it.
    var worktree: String?
    /// The branch this kild measures against. Absent for an orphan: its record is gone, so
    /// nothing recorded a base and only git could guess one.
    var base: String?
    var agents: [Agent]
    /// True for a kild that exists only as a `kild/*` worktree on disk, enumerated from git
    /// because its record is gone. It has no agents and no log, and is addressed by its
    /// worktree name — without which it would have no id at all, which is precisely how
    /// abandoned trees became permanently unreclaimable.
    var orphan: Bool?

    /// Costly half — present only from `/api/kilds/status`.
    var git: GitStatus?
    var totals: CostTotals?
    var landedSha: String?
    var landed: LandedSummary?

    var isOrphan: Bool { orphan == true }
}

/// A stopped kild, recovered from disk.
///
/// **Carries no log.** The archive only grows, so shipping every stopped kild's full
/// conversation in a listing meant "list my archive" became "send me every conversation I
/// have ever had". `GET /api/kilds/:id/messages` serves an archived kild's log exactly as
/// it serves a live one.
struct ArchivedKild: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    var worktree: String?
    var agents: [Agent]
    var cwd: String?
    var base: String?
    var landedSha: String?
    var landed: LandedSummary?
    /// When the kild ended, in milliseconds. The archive's only clock — and the only way to
    /// order it, since removing the log removed the `ts` of its last message.
    ///
    /// Absent on archives written before the field existed, and deliberately without a
    /// fallback: a synthesised timestamp would be a guess presented as a fact. Sort those
    /// last rather than inventing an order for them.
    var endedAt: Double?
}

// MARK: - Messages

/// One message in a kild's log.
///
/// `from` is engine-attributed when the sender presents its credential, and only then.
/// A caller with no `Authorization` header is recorded unattributed — which is why an
/// unattributed message is not proof the operator sent it.
struct Message: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let kildId: String
    let from: String
    let to: [String]
    let text: String
    /// Wall-clock milliseconds. **Never use as a cursor** — it is `Date.now()` and can go
    /// backwards across an NTP correction or a DST shift. Paging is `seq`.
    let ts: Double
    /// Monotonic per kild, assigned by whatever owns the log. This is the cursor:
    /// `GET …/messages?since=<seq>`.
    let seq: Int
}

// MARK: - Landing

/// The report `GET /api/kilds/:id/land` returns, and `POST` returns again after executing.
///
/// The same shape for both halves is what lets the gate show its reasons before acting and
/// then confirm with the identical fields — the dry run is a real verb, not a spinner.
struct LandReport: Codable, Sendable, Equatable {
    /// Whether the land would succeed (dry run) or did (execute).
    var ok: Bool
    /// The engine's own reason for refusing, when it refused.
    var error: String?
    var ahead: Int?
    var behind: Int?
    var dirty: Bool?
    var conflictsWithBase: Bool?
    var changedFiles: [String]?
    var commits: Int?
    var files: Int?
    var landedSha: String?
}
