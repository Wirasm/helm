import Foundation

/// `bench_wire::Done` (M1, #357): an agent whose turn ended (Claude's `Stop`, a codex thread's
/// completed turn on benchd's app-server, pi's `agent_settled`) and that has not started another. Present whether or not anybody looked;
/// `seen` says whether the operator did.
package struct BenchDone: Decodable, Equatable, Sendable {
    /// When the turn ended.
    package var since: Date
    /// Whose it is: the handle of the agent that spawned it, or `operator`.
    package var to: String
    /// The operator focused its pane, or marked it seen, after the turn ended.
    package var seen: Bool

    private enum CodingKeys: String, CodingKey {
        case to, seen
        case sinceMs = "since_ms"
    }

    package init(since: Date, to: String, seen: Bool) {
        self.since = since
        self.to = to
        self.seen = seen
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        since = Date(milliseconds: try c.decode(UInt64.self, forKey: .sinceMs))
        to = try c.decode(String.self, forKey: .to)
        seen = try c.decode(Bool.self, forKey: .seen)
    }
}

/// `bench_wire::OperatorMail` (M1, #357): mail an agent sent the operator that he has not read.
package struct BenchOperatorMail: Decodable, Equatable, Sendable {
    package var unread: Int
    /// When the oldest unread message arrived.
    package var since: Date
    /// That message's subject, the agent's own words, when it gave one.
    package var subject: String?

    private enum CodingKeys: String, CodingKey {
        case unread, subject
        case sinceMs = "since_ms"
    }

    package init(unread: Int, since: Date, subject: String? = nil) {
        self.unread = unread
        self.since = since
        self.subject = subject
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unread = try c.decode(Int.self, forKey: .unread)
        since = Date(milliseconds: try c.decode(UInt64.self, forKey: .sinceMs))
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
    }
}

/// `bench_wire::Spawner` (M1, #357): who spawned a session. A kind this build does not know is
/// refused, not guessed.
package enum BenchSpawner: Decodable, Hashable, Sendable {
    case `operator`
    case agent(handle: String)

    private enum CodingKeys: String, CodingKey { case kind, handle }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "operator": self = .operator
        case "agent": self = .agent(handle: try c.decode(String.self, forKey: .handle))
        case let kind:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown spawner kind \(kind)")
        }
    }
}

extension Date {
    /// An epoch-ms time off the bench's wire.
    fileprivate init(milliseconds: UInt64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
