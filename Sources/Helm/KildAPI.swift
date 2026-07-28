import Foundation

/// Everything helm can ask of the kild engine.
///
/// A protocol rather than a concrete client, for one reason that earns its keep: the engine
/// is helm's *only* backend, so anything that cannot be tested without it cannot be tested
/// at all. A stub conforming to this runs the whole cockpit against fixed data — every view,
/// every derivation, every state transition — with no port open.
///
/// It is deliberately a thin mirror of the REST surface rather than a convenience layer.
/// One method per endpoint, named for the verb it performs. A client that quietly issued
/// two calls for one method, or cached, or retried, would be a second engine with its own
/// opinions, and the failures that produces are the hardest kind to see from the UI.
///
/// **The cheap/costly split is expressed as two methods on purpose.** `kilds()` is identity
/// and agents; `kildsStatus()` adds git and cost and is expensive enough that the engine
/// gives it its own route. Collapsing them behind one call would put a git subprocess per
/// kild behind an innocent-looking refresh — which is exactly the cost the split was created
/// to remove.
protocol KildAPI: Sendable {
    /// `GET /api/health`. `bootId` changes when the engine restarts, which is how a client
    /// learns its cached state is from a previous life.
    func health() async throws -> Health

    /// `GET /api/kilds` — the cheap half: identity, worktree, base, agents, `orphan`.
    /// No git, no cost, no logs, and therefore no subprocesses. This is what a client
    /// polling a list should read.
    ///
    /// Includes kilds enumerated from git whose engine record is gone. Those arrive with
    /// `orphan: true` and no agents — without that enumeration they would be invisible to
    /// the API entirely, which is how 116 abandoned worktrees accumulated unseen.
    func kilds() async throws -> [Kild]

    /// `GET /api/kilds/status` — the costly half. One git invocation per kild, so this
    /// belongs on a slower cadence than `kilds()`.
    func kildsStatus() async throws -> [Kild]

    /// `GET /api/kilds/archive` — stopped kilds. **Carries no log**; use `messages(in:)`
    /// for an archived kild's conversation exactly as for a live one.
    func archive() async throws -> [ArchivedKild]

    /// `GET /api/kilds/:id/messages`, optionally from a cursor.
    ///
    /// `since` is a `seq`, never a timestamp — `ts` is wall-clock and can move backwards.
    func messages(in kild: Kild.ID, since seq: Int?) async throws -> [Message]

    /// `POST /api/kilds/:id/messages`.
    ///
    /// There is no `from` parameter, and that is the design: the engine attributes the
    /// sender from the credential. A caller that could name itself could name anyone, and
    /// PRP's authority model is deference *to a handle* — so a forgeable handle forges the
    /// authority with it.
    ///
    /// `to` is required. The engine never infers a recipient.
    func send(to recipients: [String], text: String, in kild: Kild.ID) async throws

    /// `GET /api/kilds/:id/land` — the dry run. Reports whether the land would succeed and
    /// why not. Touches nothing.
    func landDryRun(_ kild: Kild.ID) async throws -> LandReport

    /// `POST /api/kilds/:id/land` — execute. Returns the same shape as the dry run, which
    /// is what lets the gate show its reasons and then confirm against identical fields.
    func land(_ kild: Kild.ID) async throws -> LandReport

    /// `DELETE /api/kilds/:id` — disposal.
    ///
    /// Guarded on *authored commits*, not on a clean tree. Clean-vs-dirty does not survive
    /// contact with how agents actually run: on the machine that measured this, 27 of 27
    /// agent worktrees were dirty from provisioning litter written before any agent started.
    /// A guard that refused dirty trees would have refused all of them.
    ///
    /// Returns what was removed and what went with it. **A refusal throws** — it is not a
    /// failure but the guard working, and the thrown error carries the engine's reason.
    ///
    /// `force` overrides the unlanded-commit refusal and nothing else. It never risks
    /// commits: the `kild/<worktree>` branch survives every path, so forcing discards the
    /// working tree, not the work. Requiring it explicitly is what keeps the default safe.
    @discardableResult
    func delete(_ kild: Kild.ID, force: Bool) async throws -> DisposalReport

    /// `POST /api/kilds/:id/stop` — halt every agent. The tree survives.
    func stop(_ kild: Kild.ID) async throws

    /// `DELETE /api/kilds/:id/agents/:handle` — stop one agent without halting the kild.
    func stopAgent(_ handle: String, in kild: Kild.ID) async throws

    /// `GET /api/kilds/:id/agents/:handle/transcript` — an OWNED agent's own turns, read
    /// from its pi session file.
    ///
    /// **Only valid for owned agents.** An attached agent has no session file, and the
    /// engine refuses rather than returning an empty transcript — correctly, since empty
    /// would imply an agent that had done nothing. Check `Conversation.source(for:)` before
    /// calling; an attached agent's conversation lives in the kild's message log.
    func transcript(of handle: String, in kild: Kild.ID) async throws -> AgentTranscript

    /// `GET /api/personas` — the personas available to spawn with. Opaque strings; helm
    /// lists them and never interprets them.
    func personas() async throws -> [String]
}

/// `GET /api/health`.
struct Health: Codable, Sendable, Equatable {
    let ok: Bool
    /// Changes on every engine restart. A client that kept state across a change is holding
    /// state from an engine that no longer exists.
    let bootId: String
}

/// Why a call failed.
///
/// The engine's own rejection text is kept intact rather than flattened into a status code:
/// it says things like *"refusing: 3 commits not reachable from base"*, which is the whole
/// answer, and re-deriving it client-side from a 409 would be inventing a worse version of
/// a message we already have.
enum KildAPIError: Error, Equatable, LocalizedError {
    /// The engine rejected the request and said why (`{"error": …}`).
    case engine(String)
    /// A non-2xx response with no readable engine error.
    case http(Int)
    /// The response did not decode — almost always a wire change.
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case let .engine(message): message
        case let .http(code): "engine returned HTTP \(code)"
        case let .decoding(detail): "could not read the engine's response: \(detail)"
        }
    }
}
