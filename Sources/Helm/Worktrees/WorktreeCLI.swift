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

    func worktrees(in workspacePath: String) async throws -> [Worktree] {
        let listing = try await runGit(["-C", workspacePath, "worktree", "list", "--porcelain"])
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

    func remove(path: String, in workspacePath: String) async throws {
        _ = try await runGit(["-C", workspacePath, "worktree", "remove", path])
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

    private func resolveDefaultBranch(in workspacePath: String) async -> String? {
        guard
            let result = try? await runGit([
                "-C", workspacePath, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD",
            ])
        else { return nil }
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    private func mergedState(
        of branch: String?, into defaultBranch: String?, in workspacePath: String
    ) async -> WorktreeMergedState {
        guard let branch, let defaultBranch else { return .unknown }
        do {
            _ = try await runGit([
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

    private func metadata(for path: String, exists: Bool) async -> WorktreeMetadata {
        guard exists else { return WorktreeMetadata(diskBytes: nil, directoryModifiedAt: nil) }
        let date =
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        let bytes: Int64?
        if let result = try? await run(
            executable: "/usr/bin/env", arguments: [duExecutable, "-sk", path],
            commandName: "du -sk \(path)"),
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
            executable: "/usr/bin/env",
            arguments: executableArguments,
            commandName: (["git"] + arguments).joined(separator: " "))
    }

    private func run(
        executable: String, arguments: [String], commandName: String
    ) async throws
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
        let child = WorktreeChild(process)
        do {
            try await child.run(timeout: timeout)
        } catch let failure as WorktreeChild.LaunchFailure {
            throw WorktreeCLIError(
                command: commandName, reason: .launchFailed(failure.underlying.localizedDescription)
            )
        }
        guard !child.didTimeOut else {
            throw WorktreeCLIError(command: commandName, reason: .timedOut(after: timeout))
        }
        let outputData: Data
        let errorData: Data
        do {
            outputData = try Data(contentsOf: outputURL)
            errorData = try Data(contentsOf: errorURL)
        } catch {
            throw WorktreeCLIError(
                command: commandName, reason: .unreadableOutput(error.localizedDescription))
        }
        let stderr = Self.snippet(String(decoding: errorData, as: UTF8.self))
        guard child.terminationStatus == 0 else {
            throw WorktreeCLIError(
                command: commandName,
                reason: .nonzeroExit(status: child.terminationStatus, stderr: stderr))
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

private final class WorktreeChild: @unchecked Sendable {
    struct LaunchFailure: Error { let underlying: any Error }

    private let process: Process
    private let lock = NSLock()
    private var timedOut = false
    private var launched = false
    private var terminateRequested = false

    init(_ process: Process) { self.process = process }

    var terminationStatus: Int32 { process.terminationStatus }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func run(timeout: Duration) async throws {
        try await withTaskCancellationHandler {
            let watchdog = Task {
                try await Task.sleep(for: timeout)
                markTimedOut()
                terminate()
            }
            defer { watchdog.cancel() }
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                Task.detached { [self] in
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: LaunchFailure(underlying: error))
                        return
                    }
                    markLaunched()
                    process.waitUntilExit()
                    continuation.resume()
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            terminate()
        }
    }

    private func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    private func markLaunched() {
        lock.lock()
        launched = true
        let owed = terminateRequested
        lock.unlock()
        if owed { signal() }
    }

    private func terminate() {
        lock.lock()
        terminateRequested = true
        let started = launched
        lock.unlock()
        guard started else { return }
        signal()
    }

    private func signal() {
        guard process.isRunning else { return }
        process.terminate()
    }
}
