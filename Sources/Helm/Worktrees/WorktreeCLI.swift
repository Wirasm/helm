import Foundation

protocol WorktreeClient: Sendable {
    func worktrees(in workspacePath: WorkspacePath) async throws -> [Worktree]
    func remove(path: String, in workspacePath: WorkspacePath) async throws
}

struct WorktreeCLIError: Error, Equatable, LocalizedError, Sendable {
    let command: String
    let reason: Reason

    enum Reason: Equatable, Sendable {
        case launchFailed(String)
        case nonzeroExit(status: Int32, stderr: String)
        case timedOut(after: Duration)
        case unreadableOutput(String)
        case malformedOutput(String)
    }

    var errorDescription: String? {
        switch reason {
        case let .launchFailed(reason): "Could not start \(command): \(reason)"
        case let .nonzeroExit(status, stderr):
            stderr.isEmpty
                ? "\(command) exited with status \(status)."
                : "\(command) exited with status \(status): \(stderr)"
        case let .timedOut(after): "\(command) did not answer within \(after)."
        case let .unreadableOutput(reason): "\(command) output could not be read: \(reason)"
        case let .malformedOutput(reason): "\(command) returned malformed output: \(reason)"
        }
    }
}

struct WorktreeCLI: WorktreeClient, Sendable {
    static let defaultTimeout: Duration = .seconds(20)
    static let errorSnippetLimit = 1_000

    let environment: [String: String]
    let gitExecutable: String
    let duExecutable: String
    let timeout: Duration

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        gitExecutable: String = "/usr/bin/env",
        duExecutable: String = "/usr/bin/du",
        timeout: Duration = WorktreeCLI.defaultTimeout
    ) {
        self.environment = environment
        self.gitExecutable = gitExecutable
        self.duExecutable = duExecutable
        self.timeout = timeout
    }

    func worktrees(in workspacePath: WorkspacePath) async throws -> [Worktree] {
        let listing = try await runGit([
            "-C", workspacePath.value, "worktree", "list", "--porcelain",
        ])
        let records = try Self.parsePorcelain(listing.stdout)
        let defaultBranch = await resolveDefaultBranch(in: workspacePath)

        var worktrees: [Worktree] = []
        for (index, record) in records.enumerated() {
            let exists = FileManager.default.fileExists(atPath: record.path)
            worktrees.append(
                Worktree(
                    record: record,
                    kind: .classify(branch: record.branchName),
                    metadata: await metadata(for: record.path, exists: exists),
                    mergedState: await mergedState(
                        of: record.branch, into: defaultBranch, in: workspacePath),
                    isMain: index == 0,
                    exists: exists))
        }
        return worktrees
    }

    func remove(path: String, in workspacePath: WorkspacePath) async throws {
        _ = try await runGit(["-C", workspacePath.value, "worktree", "remove", path])
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

    private func resolveDefaultBranch(in workspacePath: WorkspacePath) async -> String? {
        guard
            let result = try? await runGit([
                "-C", workspacePath.value, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD",
            ])
        else { return nil }
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    private func mergedState(
        of branch: String?, into defaultBranch: String?, in workspacePath: WorkspacePath
    ) async -> WorktreeMergedState {
        guard let branch, let defaultBranch else { return .unknown }
        do {
            _ = try await runGit([
                "-C", workspacePath.value, "merge-base", "--is-ancestor", branch, defaultBranch,
            ])
            return .merged
        } catch let error as WorktreeCLIError {
            if case .nonzeroExit(status: 1, stderr: _) = error.reason { return .unmerged }
            return .unknown
        } catch {
            return .unknown
        }
    }

    private func metadata(for path: String, exists: Bool) async -> WorktreeMetadata {
        guard exists else { return WorktreeMetadata(diskBytes: nil, directoryModifiedAt: nil) }
        let date =
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        let bytes: Int64?
        if let result = try? await run(
            arguments: [duExecutable, "-sk", path], commandName: "du -sk \(path)"),
            let kilobytes = Int64(result.stdout.split(whereSeparator: \.isWhitespace).first ?? "")
        {
            bytes = kilobytes * 1_024
        } else {
            bytes = nil
        }
        return WorktreeMetadata(diskBytes: bytes, directoryModifiedAt: date)
    }

    private func runGit(_ arguments: [String]) async throws -> ProcessResult {
        let executableArguments =
            gitExecutable == "/usr/bin/env" ? ["git"] + arguments : [gitExecutable] + arguments
        return try await run(
            arguments: executableArguments,
            commandName: (["git"] + arguments).joined(separator: " "))
    }

    private func run(arguments: [String], commandName: String) async throws -> ProcessResult {
        let result: Subprocess.Result
        do {
            result = try await Subprocess.run(
                arguments, environment: environment, timeout: timeout)
        } catch let failure as Subprocess.Failure {
            let reason: WorktreeCLIError.Reason =
                switch failure {
                case let .captureUnavailable(why): .launchFailed(why)
                case let .launchFailed(why): .launchFailed(why)
                case .timedOut: .timedOut(after: timeout)
                case let .unreadableOutput(why): .unreadableOutput(why)
                }
            throw WorktreeCLIError(command: commandName, reason: reason)
        }
        guard result.status == 0 else {
            throw WorktreeCLIError(
                command: commandName,
                reason: .nonzeroExit(
                    status: result.status,
                    stderr: result.stderrSnippet(limit: Self.errorSnippetLimit)))
        }
        return ProcessResult(stdout: String(decoding: result.stdout, as: UTF8.self))
    }

    private struct ProcessResult {
        let stdout: String
    }
}
