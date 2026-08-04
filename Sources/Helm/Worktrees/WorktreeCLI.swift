import Foundation

protocol WorktreeClient: Sendable {
    func worktrees(in workspacePath: String) async throws -> [Worktree]
    func remove(path: String, in workspacePath: String) async throws
}

struct WorktreeCLIError: Error, Equatable, LocalizedError, Sendable {
    let command: String
    let reason: Reason

    enum Reason: Equatable, Sendable {
        case launchFailed(String)
        case nonzeroExit(status: Int32, stderr: String)
        case malformedOutput(String)
    }

    var errorDescription: String? {
        switch reason {
        case let .launchFailed(reason): "Could not start \(command): \(reason)"
        case let .nonzeroExit(status, stderr):
            stderr.isEmpty
                ? "\(command) exited with status \(status)."
                : "\(command) exited with status \(status): \(stderr)"
        case let .malformedOutput(reason): "\(command) returned malformed output: \(reason)"
        }
    }
}

struct WorktreeCLI: WorktreeClient, Sendable {
    static let errorSnippetLimit = 1_000

    let environment: [String: String]
    let gitExecutable: String
    let duExecutable: String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        gitExecutable: String = "/usr/bin/env",
        duExecutable: String = "/usr/bin/du"
    ) {
        self.environment = environment
        self.gitExecutable = gitExecutable
        self.duExecutable = duExecutable
    }

    func worktrees(in workspacePath: String) async throws -> [Worktree] {
        try await Task.detached {
            let listing = try runGit(["-C", workspacePath, "worktree", "list", "--porcelain"])
            let records = try Self.parsePorcelain(listing.stdout)
            let defaultBranch = resolveDefaultBranch(in: workspacePath)

            return records.enumerated().map { index, record in
                let exists = FileManager.default.fileExists(atPath: record.path)
                return Worktree(
                    record: record,
                    kind: .classify(branch: record.branchName),
                    metadata: metadata(for: record.path, exists: exists),
                    mergedState: mergedState(
                        of: record.branch, into: defaultBranch, in: workspacePath),
                    isMain: index == 0,
                    exists: exists)
            }
        }.value
    }

    func remove(path: String, in workspacePath: String) async throws {
        try await Task.detached {
            _ = try runGit(["-C", workspacePath, "worktree", "remove", path])
        }.value
    }

    static func parsePorcelain(_ output: String) throws -> [WorktreeRecord] {
        var records: [WorktreeRecord] = []
        var fields: [String] = []

        func appendRecord() throws {
            guard !fields.isEmpty else { return }
            guard let first = fields.first, first.hasPrefix("worktree ") else {
                throw WorktreeCLIError(
                    command: "git worktree list --porcelain",
                    reason: .malformedOutput("record has no worktree path"))
            }
            let path = String(first.dropFirst("worktree ".count))
            var head: String?
            var branch: String?
            var detached = false
            var locked = false
            var prunable = false
            var bare = false
            var unknown: [String] = []
            for field in fields.dropFirst() {
                if field.hasPrefix("HEAD ") {
                    head = String(field.dropFirst(5))
                } else if field.hasPrefix("branch ") {
                    branch = String(field.dropFirst(7))
                } else if field == "detached" {
                    detached = true
                } else if field == "locked" || field.hasPrefix("locked ") {
                    locked = true
                } else if field == "prunable" || field.hasPrefix("prunable ") {
                    prunable = true
                } else if field == "bare" {
                    bare = true
                } else {
                    unknown.append(field)
                }
            }
            records.append(
                WorktreeRecord(
                    path: path, head: head, branch: branch, isDetached: detached,
                    isLocked: locked, isPrunable: prunable, isBare: bare,
                    unrecognisedFields: unknown))
        }

        for line in output.components(separatedBy: .newlines) {
            if line.isEmpty {
                try appendRecord()
                fields.removeAll(keepingCapacity: true)
            } else {
                fields.append(line)
            }
        }
        try appendRecord()
        return records
    }

    private func resolveDefaultBranch(in workspacePath: String) -> String? {
        guard
            let result = try? runGit([
                "-C", workspacePath, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD",
            ])
        else { return nil }
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    private func mergedState(
        of branch: String?, into defaultBranch: String?, in workspacePath: String
    ) -> WorktreeMergedState {
        guard let branch, let defaultBranch else { return .unknown }
        do {
            _ = try runGit([
                "-C", workspacePath, "merge-base", "--is-ancestor", branch, defaultBranch,
            ])
            return .merged
        } catch let error as WorktreeCLIError {
            if case .nonzeroExit(status: 1, stderr: _) = error.reason { return .unmerged }
            return .unknown
        } catch {
            return .unknown
        }
    }

    private func metadata(for path: String, exists: Bool) -> WorktreeMetadata {
        guard exists else { return WorktreeMetadata(diskBytes: nil, directoryModifiedAt: nil) }
        let date =
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        let bytes: Int64?
        if let result = try? run(
            executable: duExecutable, arguments: ["-sk", path], commandName: "du -sk \(path)"),
            let kilobytes = Int64(result.stdout.split(whereSeparator: \.isWhitespace).first ?? "")
        {
            bytes = kilobytes * 1_024
        } else {
            bytes = nil
        }
        return WorktreeMetadata(diskBytes: bytes, directoryModifiedAt: date)
    }

    private func runGit(_ arguments: [String]) throws -> ProcessResult {
        let executableArguments = gitExecutable == "/usr/bin/env" ? ["git"] + arguments : arguments
        return try run(
            executable: gitExecutable,
            arguments: executableArguments,
            commandName: (["git"] + arguments).joined(separator: " "))
    }

    private func run(
        executable: String, arguments: [String], commandName: String
    ) throws
        -> ProcessResult
    {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helm-worktree-\(UUID().uuidString).out")
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helm-worktree-\(UUID().uuidString).err")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        else {
            throw WorktreeCLIError(
                command: commandName,
                reason: .launchFailed("could not create temporary command capture"))
        }
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        let output: FileHandle
        let errors: FileHandle
        do {
            output = try FileHandle(forWritingTo: outputURL)
            errors = try FileHandle(forWritingTo: errorURL)
        } catch {
            throw WorktreeCLIError(
                command: commandName, reason: .launchFailed(error.localizedDescription))
        }
        defer {
            try? output.close()
            try? errors.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw WorktreeCLIError(
                command: commandName, reason: .launchFailed(error.localizedDescription))
        }
        process.waitUntilExit()
        let outputData = (try? Data(contentsOf: outputURL)) ?? Data()
        let errorData = (try? Data(contentsOf: errorURL)) ?? Data()
        let stderr = Self.snippet(String(decoding: errorData, as: UTF8.self))
        guard process.terminationStatus == 0 else {
            throw WorktreeCLIError(
                command: commandName,
                reason: .nonzeroExit(status: process.terminationStatus, stderr: stderr))
        }
        return ProcessResult(stdout: String(decoding: outputData, as: UTF8.self))
    }

    private static func snippet(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > errorSnippetLimit else { return trimmed }
        return String(trimmed.prefix(errorSnippetLimit)) + "…"
    }

    private struct ProcessResult {
        let stdout: String
    }
}
