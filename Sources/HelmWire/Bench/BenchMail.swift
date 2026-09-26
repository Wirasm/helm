import Foundation

/// The two mail verbs helm sends to benchd (#358), now that helm keeps no mailroom of its own:
/// `mail/who` (which agent is in a pane) and `mail/send` (deliver a note). Pinned against
/// `daemon/fixtures/mail-verbs.json`, which the daemon gate holds to the Rust types.
package enum BenchMailRequest: Encodable, Equatable, Sendable {
    case who(id: String, pane: UUID)
    case send(id: String, to: Handle, from: String, subject: String?, body: String)

    private enum CodingKeys: String, CodingKey { case id, verb, args }
    private enum ArgKeys: String, CodingKey { case pane, to, from, subject, body }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var args = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        switch self {
        case let .who(id, pane):
            try c.encode(id, forKey: .id)
            try c.encode("mail/who", forKey: .verb)
            try args.encode(pane.uuidString.lowercased(), forKey: .pane)
        case let .send(id, to, from, subject, body):
            try c.encode(id, forKey: .id)
            try c.encode("mail/send", forKey: .verb)
            try args.encode(to.value, forKey: .to)
            try args.encode(from, forKey: .from)
            try args.encodeIfPresent(subject, forKey: .subject)
            try args.encode(body, forKey: .body)
        }
    }
}

/// `mail/who`'s answer: the mailbox of the agent whose hook last reported from the pane.
package struct BenchMailWho: Decodable, Equatable, Sendable {
    package var handle: Handle
    /// The harness, as benchd spells it: `claude`, `codex` or `pi`.
    package var harness: String
    package var session: String

    package init(handle: Handle, harness: String, session: String) {
        self.handle = handle
        self.harness = harness
        self.session = session
    }
}

/// `mail/send`'s answer, reduced to what helm reads: the id the message got.
package struct BenchMailSent: Decodable, Equatable, Sendable {
    package var id: String
}
