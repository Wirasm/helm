import Foundation
import HelmWire

@testable import Helm

/// `BenchHost` on this machine, for tests that need no benchd: the commands run here through
/// `Subprocess`, with benchd's rules for finding them (`benchd/src/commands.rs`) — `archon` from
/// `<homeDirectory>/.bun/bin`, which is also put first on its `PATH`, and `ARCHON_HOME` when
/// asked. `gitExecutable` points `git` at a stub.
///
/// It is also what `FakeBenchd.answersCommands` runs a verb with, so a test can drive helm's real
/// path over the wire against real git in a temp repository.
struct LocalBenchHost: BenchHost {
    var environment: [String: String]
    var gitExecutable: String?
    var homeDirectory: String

    init(environment: [String: String], gitExecutable: String? = nil, homeDirectory: String) {
        self.environment = environment
        self.gitExecutable = gitExecutable
        self.homeDirectory = homeDirectory
    }

    func run(_ command: BenchCommand, timeout: Duration) async throws -> Subprocess.Result {
        let (arguments, cwd, environment) = invocation(command)
        return try await Subprocess.run(
            arguments, cwd: cwd, environment: environment, timeout: timeout)
    }

    /// argv for `/usr/bin/env`, the working directory, and the environment.
    func invocation(_ command: BenchCommand) -> ([String], String?, [String: String]) {
        switch command {
        case let .git(args, cwd):
            return ([gitExecutable ?? "git"] + args, cwd, environment)
        case let .archon(args, cwd, home):
            let bun = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".bun/bin").path
            var environment = Subprocess.environment(inherited: environment, prepending: [bun])
            if let home { environment["ARCHON_HOME"] = home }
            return (["archon"] + args, cwd, environment)
        }
    }

    func existing(_ paths: [String]) async throws -> Set<String> {
        try Self.existing(paths)
    }

    /// benchd's rule (`commands::exists`): symlinks followed, a missing path or one under a file
    /// is absent, and anything else — a folder it may not search — refuses the whole answer, never
    /// "absent", because a worktree read as missing is pruned.
    static func existing(_ paths: [String]) throws -> Set<String> {
        var found: Set<String> = []
        for path in paths {
            var info = stat()
            if stat(path, &info) == 0 {
                found.insert(path)
            } else if errno != ENOENT && errno != ENOTDIR {
                throw BenchHostFailure(
                    reason:
                        "cannot tell whether \(path) exists: \(String(cString: strerror(errno)))")
            }
        }
        return found
    }

    func repositories(workspaces: [String]) async throws -> [BenchGitRepository] {
        throw BenchHostFailure(reason: "LocalBenchHost does not search for repositories")
    }
}

extension FakeBenchd {
    /// Answer `command/run` and `path/exists` by doing them here, as benchd would on its machine,
    /// so helm's own code runs its whole path over the wire. Anything else is refused.
    func answersCommands(with host: LocalBenchHost) {
        answer = { request in
            let id = request["id"] ?? ""
            let args = request["args"] as? [String: Any] ?? [:]
            switch request["verb"] as? String {
            case "command/run":
                let command = args["command"] as? [String: Any] ?? [:]
                let argv = command["args"] as? [String] ?? []
                let cwd = command["cwd"] as? String
                let typed: BenchCommand =
                    command["program"] as? String == "archon"
                    ? .archon(args: argv, cwd: cwd ?? "/", home: command["home"] as? String)
                    : .git(args: argv, cwd: cwd)
                let (arguments, directory, environment) = host.invocation(typed)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = arguments
                process.environment = environment
                if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    return ["id": id, "status": "refused", "reason": "cannot start: \(error)"]
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return [
                    "id": id, "status": "ok",
                    "data": [
                        "kind": "exited", "status": process.terminationStatus,
                        "stdout": stdout.base64EncodedString(),
                        "stderr": stderr.base64EncodedString(),
                    ],
                ]
            case "path/exists":
                let paths = args["paths"] as? [String] ?? []
                do {
                    let found = try LocalBenchHost.existing(paths)
                    return [
                        "id": id, "status": "ok",
                        "data": ["existing": paths.filter(found.contains)],
                    ]
                } catch {
                    return ["id": id, "status": "refused", "reason": error.localizedDescription]
                }
            default:
                return ["id": id, "status": "refused", "reason": "not answered here"]
            }
        }
    }
}
