import Foundation

/// `sessions/log` (#625): one session's transcript, as `bench log` reads it, for Pocket's chat.
/// `id` is a session id as a `sessions/all` row carries it. Pinned against
/// `daemon/fixtures/session-log.json`, which the daemon gate reads into `bench_wire::SessionLogArgs`.
package struct BenchSessionLogRequest: Encodable, Equatable, Sendable {
    package enum Page: Equatable, Sendable {
        /// The last `limit` entries.
        case last
        /// Up to `limit` entries after this index: what arrived since.
        case after(Int)
        /// Up to `limit` entries before this index: older ones.
        case before(Int)
    }

    package var id: String
    package var session: String
    package var page: Page
    package var limit: Int

    package init(id: String, session: String, page: Page, limit: Int = 50) {
        self.id = id
        self.session = session
        self.page = page
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args }
    private enum ArgKeys: String, CodingKey { case id, before, after, limit }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("sessions/log", forKey: .verb)
        var args = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        try args.encode(session, forKey: .id)
        switch page {
        case .last: break
        case let .after(index): try args.encode(index, forKey: .after)
        case let .before(index): try args.encode(index, forKey: .before)
        }
        try args.encode(limit, forKey: .limit)
    }
}

/// `sessions/log`'s answer: entries in transcript order, and how many the transcript holds.
package struct BenchSessionLog: Decodable, Equatable, Sendable {
    package var total: Int
    package var entries: [BenchLogEntry]

    package init(total: Int, entries: [BenchLogEntry]) {
        self.total = total
        self.entries = entries
    }
}

/// One transcript entry (`bench_wire::SessionLogEntry`) and its index, the cursor.
package struct BenchLogEntry: Decodable, Equatable, Sendable, Identifiable {
    package enum Kind: String, Decodable, Sendable {
        /// A prompt: the operator's, a spawner's, or a notice delivered as a turn.
        case user
        /// The agent's reply.
        case agent
        /// One tool call: `tool` names it, `text` is a short argument.
        case tool
        /// A failed tool call or an error the harness recorded.
        case error
    }

    package var index: Int
    package var at: String
    package var kind: Kind
    package var tool: String?
    package var text: String

    package var id: Int { index }

    package init(index: Int, at: String, kind: Kind, tool: String? = nil, text: String) {
        self.index = index
        self.at = at
        self.kind = kind
        self.tool = tool
        self.text = text
    }
}
