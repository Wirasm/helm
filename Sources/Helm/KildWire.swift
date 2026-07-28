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

    /// **Waiting on a human.** The one definition, because it was previously spelled out at
    /// six call sites — four as `isIdle && !isStopped` and one, in the land gate, as its
    /// inverse written independently. A condition added to "waiting" would have had to be
    /// added in four places and *removed* in a fifth, in the opposite direction.
    ///
    /// `idle` alone is not enough: a stopped agent's process is gone, so nobody can unblock
    /// it, and counting it would inflate the attention badge with agents no human action
    /// can help.
    var isWaiting: Bool { isIdle && !isStopped }

    /// **Actively working.** Not the negation of `isWaiting` — a stopped agent is neither,
    /// which is why both are stated rather than one derived from the other. The land gate
    /// blocks on this: landing under an agent that is still working races its next commit,
    /// while landing under an idle or stopped one does not.
    var isWorking: Bool { !isIdle && !isStopped }
}

// MARK: - Git

/// A kild's git position, relative to its base branch.
///
/// **Presence of this object is what "measured" means.** The whole block is optional on a
/// kild — the cheap listing omits it, and an orphan has no record to measure — but once
/// present, every field below is present too. The engine's own note: *"Every field has a
/// safe default so a probe failure still yields a well-formed object; the failure detail
/// lands in `error`."*
///
/// That safety is a trap for a client that does not read `error`. A failed probe returns
/// `ahead: 0`, `dirty: false`, `changedFiles: []` — values indistinguishable from a clean,
/// up-to-date tree. Rendering them as facts would show a reassuring green gate built on a
/// measurement that never happened, which is why `isTrustworthy` exists and why every
/// consumer here checks it.
struct GitStatus: Codable, Sendable, Equatable {
    var path: String
    /// Null on a detached HEAD.
    var branch: String?
    var base: String
    var ahead: Int
    var behind: Int
    var dirty: Bool
    /// A **count**, not a list — the engine sends an integer here despite the plural.
    var uncommittedFiles: Int
    /// Paths changed relative to base. Always present when `git` is; the input to collision
    /// derivation, which no single kild can perform for itself.
    var changedFiles: [String]
    /// Would HEAD merge into base cleanly? **`nil` means undetermined, not "yes".**
    ///
    /// The engine says so explicitly (`null = undetermined`), and the difference matters on
    /// the land gate: reading absence as "merges without conflict" would state a guarantee
    /// the engine deliberately declined to make.
    var conflictsWithBase: Bool?
    /// Any git failure, captured rather than thrown. Its presence means the numbers above
    /// are defaults, not measurements.
    var error: String?

    /// Whether these numbers describe the repository or merely survived a failure.
    ///
    /// Read this before treating any other field as a fact. Nothing here is nil-able on
    /// failure — that is exactly the problem — so the only signal is `error`.
    var isTrustworthy: Bool { error == nil }

    /// `true` only when the engine actively determined the merge is clean.
    ///
    /// Deliberately optional rather than defaulting: `nil` (undetermined) and `false`
    /// (conflicts) are both "not known to be safe", but only one of them is a conflict, and
    /// a gate that conflates them would report a conflict that was never found.
    var mergesCleanly: Bool? {
        guard isTrustworthy else { return nil }
        return conflictsWithBase.map { !$0 }
    }
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

/// One commit a land would carry.
struct ReviewCommit: Codable, Sendable, Equatable, Identifiable {
    let sha: String
    let subject: String
    let author: String
    let ts: Double
    let filesChanged: Int
    let additions: Int
    let deletions: Int

    var id: String { sha }
}

/// The report `GET /api/kilds/:id/land` returns, and `POST` returns again after executing.
///
/// The same shape for both halves is what lets the gate show its reasons before acting and
/// then confirm against identical fields — the dry run is a real verb, not a spinner.
///
/// **Captured from the running engine, not written from the docs.** An earlier version of
/// this type was invented from an API sketch and shared not one field name with the wire;
/// because `ok` was required and never sent, every single land call — dry run included —
/// failed to decode. The GET returns 200 for landable and blocked alike, so there was no
/// path on which it worked. The lesson is the one this file's own header states and that
/// version ignored: mirror what the engine sends, and prove it with a captured payload.
struct LandReport: Codable, Sendable, Equatable {
    /// Base branch this would land into.
    let base: String
    /// The branch being landed, when git could name it.
    let branch: String?
    /// Commits the land carries, newest first. **Empty means nothing to land** — there is
    /// no separate ahead/behind count on this route.
    let commits: [ReviewCommit]
    /// Files the branch changed against base.
    let files: [String]
    /// Paths that conflict when merging into base — the engine's own collision preview.
    ///
    /// Not to be confused with helm's cross-kild derivation. This one is *this branch
    /// against its base*; that one is *two live kilds against each other*. Both belong on
    /// the gate, and only the second is derived.
    let collides: [String]
    /// Whether the merge would apply, or did.
    let wouldMerge: Bool
    /// True only for a merge that actually happened.
    let merged: Bool
    /// The merge commit — present only when `merged`.
    var sha: String?
    /// Why it would not or did not land, or any git failure. Never thrown.
    var error: String?
    /// Set by the route: `true` for the GET, `false` for the POST.
    var dryRun: Bool?
}

// MARK: - Transcripts

/// One turn in an owned agent's transcript.
///
/// `GET /api/kilds/:id/agents/:handle/transcript` reads pi's session file, so this is the
/// agent's own record of its work rather than anything kild composed.
struct TranscriptEntry: Codable, Sendable, Equatable {
    /// `user`, `assistant`, or `tool`. Left as the string the wire sends rather than an
    /// enum: an unrecognised role should render as itself, not fail the whole transcript.
    /// A new role added engine-side is a rendering question, never a decode failure.
    let role: String
    let text: String
    /// Tool names this turn invoked. Present on `assistant` turns; an assistant turn that
    /// only called tools carries an empty `text`, which is why a renderer must read both.
    var toolCalls: [String]?
}

/// An owned agent's transcript.
///
/// **Only owned agents have one.** The route reads the agent's pi session file, and an
/// attached agent has none — kild never spawned it, so there is no session to read. The
/// engine says so plainly rather than returning an empty transcript:
/// `{"error": "agent @x has no pi session file (yet)"}`. An empty result would imply an
/// agent that had done nothing; the error correctly says helm is asking the wrong question.
///
/// For an attached agent the conversation is the routed messages in the kild log — see
/// `Conversation.forAgent`.
struct AgentTranscript: Codable, Sendable, Equatable {
    let entries: [TranscriptEntry]
    let total: Int
}
