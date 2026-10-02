import Foundation

// prp's stores and the paths the operator types, as helm asks benchd about them (M5c, #459).
// `~/.prp` lives on the agents' machine, which is benchd's, so helm never reads it itself. The
// spelling is `bench_wire::prp`; `daemon/fixtures/prp-verbs.json` pins both sides.

/// One of the four questions, with its arguments.
package struct BenchPrpRequest: Encodable, Equatable, Sendable {
    package enum Verb: Equatable, Sendable {
        /// Start an operator note in the workspace's store; `day` is `yyyy-MM-dd`.
        case note(workspace: String, day: String)
        /// Every store, and the workspace's when one is named.
        case stores(workspace: String?)
        /// One store's renderable files, by key.
        case artifacts(store: String)
        /// A typed path, `~` expanded against benchd's home.
        case resolvePath(String)
    }

    package var id: String
    package var verb: Verb

    package init(id: String, _ verb: Verb) {
        self.id = id
        self.verb = verb
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args }
    private enum ArgKeys: String, CodingKey { case workspace, day, store, path }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        var a = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        switch verb {
        case let .note(workspace, day):
            try c.encode("prp/note", forKey: .verb)
            try a.encode(workspace, forKey: .workspace)
            try a.encode(day, forKey: .day)
        case let .stores(workspace):
            try c.encode("prp/stores", forKey: .verb)
            try a.encodeIfPresent(workspace, forKey: .workspace)
        case let .artifacts(store):
            try c.encode("prp/artifacts", forKey: .verb)
            try a.encode(store, forKey: .store)
        case let .resolvePath(path):
            try c.encode("path/resolve", forKey: .verb)
            try a.encode(path, forKey: .path)
        }
    }
}

/// `prp/note`'s answer: the new, empty note on benchd's machine.
package struct BenchPrpNote: Decodable, Equatable, Sendable {
    package var path: String
}

/// One store (`bench_wire::PrpStore`).
package struct BenchPrpStore: Decodable, Equatable, Sendable, Identifiable {
    package var key: String
    /// `project.json`'s name, else the key.
    package var name: String
    /// `project.json`'s path: the project root the store belongs to.
    package var path: String?
    package var dir: String

    package var id: String { key }

    package init(key: String, name: String, path: String?, dir: String) {
        self.key = key
        self.name = name
        self.path = path
        self.dir = dir
    }
}

/// `prp/stores`'s answer: sorted by name, and the workspace's store key when it has one.
package struct BenchPrpStores: Decodable, Equatable, Sendable {
    package var stores: [BenchPrpStore]
    package var workspace: String?

    package init(stores: [BenchPrpStore], workspace: String? = nil) {
        self.stores = stores
        self.workspace = workspace
    }
}

/// One renderable file in a store.
package struct BenchPrpArtifact: Decodable, Equatable, Sendable {
    package var path: String
    /// Under the store, as the browser shows it: `plans/foo.plan.md`.
    package var relative: String
    package var modifiedMs: UInt64

    package init(path: String, relative: String, modifiedMs: UInt64) {
        self.path = path
        self.relative = relative
        self.modifiedMs = modifiedMs
    }

    private enum CodingKeys: String, CodingKey {
        case path, relative
        case modifiedMs = "modified_ms"
    }
}

/// `prp/artifacts`'s answer, newest first.
package struct BenchPrpArtifacts: Decodable, Equatable, Sendable {
    package var files: [BenchPrpArtifact]
}

/// `path/resolve`'s answer: benchd's absolute path, and what is there.
package struct BenchPathResolved: Decodable, Equatable, Sendable {
    package enum Kind: String, Decodable, Sendable {
        case file, directory
    }

    package var path: String
    package var kind: Kind

    package init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}
