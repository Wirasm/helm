import Foundation

protocol ArchonClient: Sendable {
    func activeRuns() async throws -> [ArchonRun]
    func workflows(in workspacePath: String) async throws -> ArchonWorkflowListResponse
    func run(id: String) async throws -> ArchonRun
    func launch(_ request: ArchonLaunchRequest) async throws -> ArchonLaunchAcknowledgement
}

enum ArchonCLIError: Error, Equatable, LocalizedError, Sendable {
    case launchFailed(String)
    case nonzeroExit(Int32)
    case unreadableOutput(String)
    case emptyOutput
    case malformedJSON(String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(reason): "Archon is unavailable: \(reason)"
        case let .nonzeroExit(status): "Archon exited with status \(status)."
        case let .unreadableOutput(reason): "Archon output could not be read: \(reason)"
        case .emptyOutput: "Archon returned no data."
        case let .malformedJSON(reason): "Archon returned malformed data: \(reason)"
        }
    }
}

/// The sole process and JSON boundary for Archon. stdout goes to a regular temporary file:
/// Archon's large JSON payloads have been measured truncating silently when captured by Pipe.
struct ArchonCLI: ArchonClient, Sendable {
    let inheritedEnvironment: [String: String]
    let homeDirectory: String
    let captureDirectory: URL

    init(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        captureDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.inheritedEnvironment = inheritedEnvironment
        self.homeDirectory = homeDirectory
        self.captureDirectory = captureDirectory
    }

    func activeRuns() async throws -> [ArchonRun] {
        try await decode(ArchonStatusResponse.self, arguments: ["workflow", "status", "--json"])
            .runs
    }

    func workflows(in workspacePath: String) async throws -> ArchonWorkflowListResponse {
        try await decode(
            ArchonWorkflowListResponse.self,
            arguments: ["workflow", "list", "--json", "--cwd", workspacePath])
    }

    func run(id: String) async throws -> ArchonRun {
        try await decode(
            ArchonRun.self,
            arguments: ["workflow", "get", id, "--json", "--verbose"])
    }

    func launch(_ request: ArchonLaunchRequest) async throws -> ArchonLaunchAcknowledgement {
        var arguments = [
            "workflow", "run", request.workflow, request.input, "--detach", "--json", "--cwd",
            request.workspacePath,
        ]
        if request.noWorktree {
            arguments.append("--no-worktree")
        } else if let branch = request.branch {
            arguments += ["--branch", branch]
        }
        return try await decode(ArchonLaunchAcknowledgement.self, arguments: arguments)
    }

    static func developmentEnvironment(
        inherited: [String: String], homeDirectory: String
    ) -> [String: String] {
        var environment = inherited
        let developmentBin = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".bun/bin").path
        let inheritedPath = inherited["PATH"].flatMap { $0.isEmpty ? nil : $0 }
        environment["PATH"] = [developmentBin, inheritedPath].compactMap { $0 }.joined(
            separator: ":")
        return environment
    }

    private func decode<T: Decodable>(_ type: T.Type, arguments: [String]) async throws -> T {
        let data = try await capture(arguments: arguments)
        do {
            return try JSONDecoder.archon().decode(type, from: data)
        } catch {
            throw ArchonCLIError.malformedJSON(error.localizedDescription)
        }
    }

    private func capture(arguments: [String]) async throws -> Data {
        let environment = Self.developmentEnvironment(
            inherited: inheritedEnvironment, homeDirectory: homeDirectory)
        let directory = captureDirectory
        return try await Task.detached {
            let outputURL = directory.appendingPathComponent(
                "helm-archon-\(UUID().uuidString).json")
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
                throw ArchonCLIError.unreadableOutput("could not create temporary capture")
            }
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let output: FileHandle
            do {
                output = try FileHandle(forWritingTo: outputURL)
            } catch {
                throw ArchonCLIError.unreadableOutput(error.localizedDescription)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["archon"] + arguments
            process.environment = environment
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                try? output.close()
                throw ArchonCLIError.launchFailed(error.localizedDescription)
            }
            try? output.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ArchonCLIError.nonzeroExit(process.terminationStatus)
            }

            let data: Data
            do {
                data = try Data(contentsOf: outputURL)
            } catch {
                throw ArchonCLIError.unreadableOutput(error.localizedDescription)
            }
            guard !data.isEmpty,
                !String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ArchonCLIError.emptyOutput }
            return data
        }.value
    }
}
