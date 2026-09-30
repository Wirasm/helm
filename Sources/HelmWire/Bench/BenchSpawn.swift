import Foundation

/// `spawn` as helm sends it (#535): a read-only fork of the Claude Code conversation that opened a
/// canvas, asked for by the operator from a mark. Only the fields helm uses; the rest of benchd's
/// `SpawnArgs` is the `bench` CLI's. Pinned against `daemon/fixtures/spawn-verbs.json`.
///
/// **Sent `by: helm`**, the one actor benchd never moves focus for (`Actor::focus`): the operator
/// asked for the fork, not for his keyboard, so it appears beside his work (#125).
///
/// **The prompt travels as text.** helm can reach benchd over TCP (M5c), and then no file helm
/// writes is on benchd's disk; benchd writes it under its own root, where it outlives the spawn.
package struct BenchForkRequest: Encodable, Equatable, Sendable {
    package var id: String
    /// The conversation to fork: the canvas's `author.session`.
    package var fork: String
    /// Where the fork runs: the author's own cwd, which is where Claude Code finds the transcript.
    package var cwd: String
    /// The fork's first prompt.
    package var prompt: String

    package init(id: String, fork: String, cwd: String, prompt: String) {
        self.id = id
        self.fork = fork
        self.cwd = cwd
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args, by }
    private enum ArgKeys: String, CodingKey { case agent, cwd, fork, prompt }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("spawn", forKey: .verb)
        try c.encode(BenchActor.helm, forKey: .by)
        var args = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        // Claude Code is the only runtime benchd can fork (#531).
        try args.encode("claude", forKey: .agent)
        try args.encode(cwd, forKey: .cwd)
        try args.encode(fork, forKey: .fork)
        try args.encode(prompt, forKey: .prompt)
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
