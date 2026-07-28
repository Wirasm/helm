import Foundation

/// What one agent's tab shows.
///
/// `ownership` decides the *source*, not merely the fidelity — this is sharper than it first
/// looks, and getting it wrong means asking the engine a question it cannot answer:
///
/// - **owned** — kild spawned the process, so pi wrote a session file and
///   `GET …/agents/:handle/transcript` reads it. Full turns: prose, tool calls, roles.
/// - **attached** — kild never spawned it, so **there is no transcript at all**. The route
///   does not return an empty one, it refuses: *"agent @x has no pi session file (yet)"* —
///   correctly, because an empty transcript would imply an agent that had done nothing,
///   when the truth is that helm asked the wrong question. Its conversation is the messages
///   the engine itself routed, filtered out of the kild log.
///
/// So the two tabs are not the same view with different amounts of data. They read from
/// different places, and only one of them can ever be asked for a transcript.
enum Conversation {

    /// A single line to render, from either source.
    ///
    /// Deliberately not a merge of the two shapes into some richest-common-denominator: an
    /// attached agent's line genuinely has no role and no tool calls, and inventing empty
    /// ones would make the view look like it was showing a sparse transcript rather than a
    /// different kind of record.
    enum Line: Equatable, Identifiable {
        /// A turn from an owned agent's own session file.
        case turn(index: Int, role: String, text: String, toolCalls: [String])
        /// A message the engine routed, with its attributed sender.
        case message(from: String, to: [String], text: String, seq: Int)

        var id: String {
            switch self {
            // Positional, because a transcript entry has no wire id and its CONTENT is not
            // unique: a tool-only turn carries `text: ""`, so two consecutive ones hash
            // identically. `ForEach` on colliding ids silently drops rows — a transcript
            // that quietly loses the turns that did the most work.
            case let .turn(index, _, _, _): "turn-\(index)"
            case let .message(_, _, _, seq): "msg-\(seq)"
            }
        }

        var text: String {
            switch self {
            case let .turn(_, _, text, _): text
            case let .message(_, _, text, _): text
            }
        }
    }

    /// Which source an agent's tab must read. Callers switch on this rather than on
    /// `ownership` directly, so the reason is named at the point of decision.
    enum Source: Equatable {
        /// `GET /api/kilds/:id/agents/:handle/transcript`
        case transcript
        /// The kild's message log, filtered to this handle.
        case routedMessages
    }

    static func source(for agent: Agent) -> Source {
        agent.ownership == .owned ? .transcript : .routedMessages
    }

    /// Render an owned agent's transcript.
    ///
    /// An assistant turn that only called tools carries an empty `text`, so a renderer that
    /// reads only `text` would silently drop the most informative turns — the ones that did
    /// something. Empty turns with no tool calls are dropped; empty turns *with* tool calls
    /// are kept, because the tool call is the content.
    ///
    /// **The index is absolute, not window-relative, and that is load-bearing.** The
    /// transcript route serves a sliding TAIL — `entries.slice(-50)` by default, with `total`
    /// reporting the full count. Once a session passes the window, every poll drops entries
    /// off the front, so a turn that was `entries[3]` becomes `entries[2]` moments later.
    /// Keying identity on the window position would give every surviving line a new id on
    /// every tick: `ForEach` sees the whole transcript removed and reinserted, reflows, and
    /// throws away scroll position — the same failure the positional id was introduced to
    /// fix, reintroduced by windowing instead of by hash collision.
    ///
    /// `total - entries.count` recovers where the window starts, so an entry keeps one id
    /// for as long as it exists.
    static func lines(from transcript: AgentTranscript) -> [Line] {
        let windowStart = max(0, transcript.total - transcript.entries.count)
        return transcript.entries.enumerated().compactMap { index, entry in
            let tools = entry.toolCalls ?? []
            guard !entry.text.isEmpty || !tools.isEmpty else { return nil }
            return .turn(
                index: windowStart + index, role: entry.role, text: entry.text,
                toolCalls: tools)
        }
    }

    /// Everything an attached agent said or was told, from the kild log.
    ///
    /// Both directions are included: a tab showing only what the agent *said* would omit
    /// the instructions it was answering, which is most of what makes a conversation
    /// readable. Ordered by `seq`, never by `ts` — `ts` is wall-clock and can move
    /// backwards, which would silently reorder the conversation.
    static func lines(for handle: String, from log: [Message]) -> [Line] {
        log
            .filter { $0.from == handle || $0.to.contains(handle) }
            .sorted { $0.seq < $1.seq }
            .map { .message(from: $0.from, to: $0.to, text: $0.text, seq: $0.seq) }
    }

    /// Why an attached agent's tab is sparse, stated in the UI rather than left to look
    /// like a loading failure.
    ///
    /// The distinction matters: an empty owned transcript means the agent has not worked
    /// yet, while an empty attached one means the engine has nothing to show and never
    /// will. Same emptiness, opposite meanings, and only one of them is worth waiting on.
    static func emptyExplanation(for agent: Agent) -> String {
        switch agent.ownership {
        case .owned:
            "no turns yet"
        case .attached:
            "kild did not spawn this agent and cannot see inside it — "
                + "this is everything the engine has"
        }
    }
}
