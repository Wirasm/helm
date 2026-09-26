import Foundation

/// `just/run` as helm sends it (#356): a recipe from the operator's bench justfile, run by
/// benchd **as the operator**, because helm only sends it for his key. Pinned against
/// `daemon/fixtures/just-verbs.json`, which the daemon gate holds to `bench_wire::just`.
package struct BenchJustRequest: Encodable, Equatable, Sendable {
    package var id: String
    package var recipe: String
    package var args: [String]

    package init(id: String, recipe: String, args: [String] = []) {
        self.id = id
        self.recipe = recipe
        self.args = args
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args, by }
    private enum ArgKeys: String, CodingKey { case recipe, args }
    private enum ByKeys: String, CodingKey { case kind }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("just/run", forKey: .verb)
        var a = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        try a.encode(recipe, forKey: .recipe)
        if !args.isEmpty { try a.encode(args, forKey: .args) }
        var by = c.nestedContainer(keyedBy: ByKeys.self, forKey: .by)
        try by.encode("operator", forKey: .kind)
    }
}

/// `just/run`'s answer: the run started, and where its output goes.
package struct BenchJustStarted: Decodable, Equatable, Sendable {
    package var run: String
    package var log: String

    package init(run: String, log: String) {
        self.run = run
        self.log = log
    }
}

/// `just/finished`'s data (`bench_wire::JustFinished`).
package struct BenchJustFinished: Decodable, Equatable, Sendable {
    package var run: String
    package var recipe: String
    /// nil when a signal ended the run.
    package var exit: Int?
    package var log: String

    package var failed: Bool { exit != 0 }
}

/// A frame whose event carries data helm reads — one kind at a time, decoded where it is used.
package struct BenchEventFrame<Payload: Decodable & Sendable>: Decodable, Sendable {
    package var event: Event

    package struct Event: Decodable, Sendable {
        package var kind: String
        package var data: Payload
    }
}
