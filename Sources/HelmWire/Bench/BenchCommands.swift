import Foundation

// What helm asks of benchd's machine rather than its own (M5c, #459): the drawers' `git` and
// `archon`, whether a path exists there, and which repositories there are. The spelling is
// `bench_wire::commands`; `daemon/fixtures/command-verbs.json` pins both sides.

/// The program `command/run` runs. Two, tagged by `program`: benchd resolves each on its own
/// machine (`archon` from its `~/.bun/bin`), so helm names the program and never a path to it.
package enum BenchCommand: Equatable, Sendable {
    /// `git`; most calls name their repository with `-C`, so the directory is optional.
    case git(args: [String], cwd: String? = nil)
    /// `archon`, in the directory it resolves its project from. `home` is `ARCHON_HOME`.
    case archon(args: [String], cwd: String, home: String? = nil)

    /// As typed, for an error the operator can run himself.
    package var line: String {
        switch self {
        case let .git(args, _): (["git"] + args).joined(separator: " ")
        case let .archon(args, _, _): (["archon"] + args).joined(separator: " ")
        }
    }
}

/// `command/run`: run one command on benchd's machine, killed after `timeoutMs`.
package struct BenchCommandRunRequest: Encodable, Equatable, Sendable {
    package var id: String
    package var command: BenchCommand
    package var timeoutMs: UInt64

    package init(id: String, command: BenchCommand, timeoutMs: UInt64) {
        self.id = id
        self.command = command
        self.timeoutMs = timeoutMs
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args }
    private enum ArgKeys: String, CodingKey { case command, timeoutMs = "timeout_ms" }
    private enum CommandKeys: String, CodingKey { case program, args, cwd, home }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("command/run", forKey: .verb)
        var a = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        try a.encode(timeoutMs, forKey: .timeoutMs)
        var p = a.nestedContainer(keyedBy: CommandKeys.self, forKey: .command)
        switch command {
        case let .git(args, cwd):
            try p.encode("git", forKey: .program)
            try p.encode(args, forKey: .args)
            try p.encodeIfPresent(cwd, forKey: .cwd)
        case let .archon(args, cwd, home):
            try p.encode("archon", forKey: .program)
            try p.encode(args, forKey: .args)
            try p.encode(cwd, forKey: .cwd)
            try p.encodeIfPresent(home, forKey: .home)
        }
    }
}

/// `command/run`'s answer. A nonzero exit is an answer: only the caller knows what a status
/// means. A program benchd could not start is a refusal, not one of these.
package enum BenchCommandRun: Decodable, Equatable, Sendable {
    /// `status` is the exit code, or 128 plus the signal that ended the program.
    case exited(status: Int32, stdout: Data, stderr: Data)
    case timedOut

    private enum CodingKeys: String, CodingKey { case kind, status, stdout, stderr }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "exited":
            func bytes(_ key: CodingKeys) throws -> Data {
                guard let data = Data(base64Encoded: try c.decode(String.self, forKey: key)) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key, in: c, debugDescription: "base64 that does not decode")
                }
                return data
            }
            self = .exited(
                status: try c.decode(Int32.self, forKey: .status), stdout: try bytes(.stdout),
                stderr: try bytes(.stderr))
        case "timed_out": self = .timedOut
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "a command/run answer of kind \(other)")
        }
    }
}

/// `path/exists`: which of these absolute paths exist on benchd's machine.
package struct BenchPathExistsRequest: Encodable, Equatable, Sendable {
    package var id: String
    package var paths: [String]

    package init(id: String, paths: [String]) {
        self.id = id
        self.paths = paths
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args }
    private enum ArgKeys: String, CodingKey { case paths }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("path/exists", forKey: .verb)
        var a = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        try a.encode(paths, forKey: .paths)
    }
}

/// `path/exists`'s answer: the asked paths that exist, as asked. A path benchd could not look at
/// is a refusal, never left out of this.
package struct BenchPathExists: Decodable, Equatable, Sendable {
    package var existing: [String]
}

/// `git/repositories`: every repository under benchd's home, the workspaces' first.
package struct BenchGitRepositoriesRequest: Encodable, Equatable, Sendable {
    package var id: String
    package var workspaces: [String]

    package init(id: String, workspaces: [String]) {
        self.id = id
        self.workspaces = workspaces
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args }
    private enum ArgKeys: String, CodingKey { case workspaces }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("git/repositories", forKey: .verb)
        var a = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        try a.encode(workspaces, forKey: .workspaces)
    }
}

/// One repository on benchd's machine, by its common git directory.
package struct BenchGitRepository: Decodable, Equatable, Sendable {
    package var commonDir: String
    /// Some bench workspace is in this repository.
    package var isWorkspace: Bool

    package init(commonDir: String, isWorkspace: Bool) {
        self.commonDir = commonDir
        self.isWorkspace = isWorkspace
    }

    private enum CodingKeys: String, CodingKey {
        case commonDir = "common_dir"
        case isWorkspace = "is_workspace"
    }
}

/// `git/repositories`'s answer.
package struct BenchGitRepositories: Decodable, Equatable, Sendable {
    package var repositories: [BenchGitRepository]
}
