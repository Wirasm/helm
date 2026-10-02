import Foundation

/// `spawn` as helm sends it: only the fields helm uses; the rest of benchd's `SpawnArgs` is the
/// `bench` CLI's. Pinned against `daemon/fixtures/spawn-verbs.json`.
///
/// **A prompt travels as text.** helm can reach benchd over TCP (M5c), and then no file helm
/// writes is on benchd's disk; benchd writes it under its own root, where it outlives the spawn.
package struct BenchSpawnRequest: Encodable, Equatable, Sendable {
    package enum Conversation: Equatable, Sendable {
        /// A read-only fork of conversation `from`, asked `prompt` (#535): the operator's question
        /// about a mark on a canvas the conversation opened. **Sent `by: helm`**, the one actor
        /// benchd never moves focus for (`Actor::focus`): the operator asked for the fork, not for
        /// his keyboard, so it appears beside his work (#125).
        case fork(from: String, prompt: String)
        /// Re-enter conversation `id`, pressed in the sessions drawer. Sent by the operator, so
        /// the pane it opens takes his keyboard; benchd sends the resume notice, and brings back
        /// the worktree it ran in when that is gone (#621).
        case resume(String)
    }

    package var id: String
    /// The harness that holds the conversation.
    package var agent: String
    /// Where the conversation ran, which is where its harness finds it.
    package var cwd: String
    package var conversation: Conversation

    package init(id: String, agent: String, cwd: String, conversation: Conversation) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.conversation = conversation
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args, by }
    private enum ArgKeys: String, CodingKey { case agent, cwd, fork, prompt, resume }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("spawn", forKey: .verb)
        var args = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        try args.encode(agent, forKey: .agent)
        try args.encode(cwd, forKey: .cwd)
        switch conversation {
        case let .fork(from, prompt):
            try c.encode(BenchActor.helm, forKey: .by)
            try args.encode(from, forKey: .fork)
            try args.encode(prompt, forKey: .prompt)
        case let .resume(session):
            try c.encode(BenchActor.operatorGesture, forKey: .by)
            try args.encode(session, forKey: .resume)
        }
    }
}

/// `spawn`'s answer, reduced to what helm's receipt names.
package struct BenchSpawned: Decodable, Equatable, Sendable {
    /// The fork's mailbox address, which is also its pane's session name.
    package var handle: String
    package var pane: UUID

    package init(handle: String, pane: UUID) {
        self.handle = handle
        self.pane = pane
    }
}
