import Foundation

/// Reads and changes one repository's worktrees through git. The repository is named by its
/// common git directory (`WorktreeRepo.commonDir`); git runs there, so a bare repository and one
/// whose main checkout was moved answer the same way.
protocol WorktreeClient: Sendable {
    /// `statusOfALoneCheckout` false skips `git status` when the main checkout is the only
    /// worktree: the drawer does not list such a repository unless a workspace is in it.
    func worktrees(
        in repository: GitCommonDir, statusOfALoneCheckout: Bool
    ) async throws
        -> [Worktree]
    func remove(path: String, in repository: GitCommonDir) async throws
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
    let timeout: Duration

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        gitExecutable: String = "/usr/bin/env",
        timeout: Duration = WorktreeCLI.defaultTimeout
    ) {
        self.environment = environment
        self.gitExecutable = gitExecutable
        self.timeout = timeout
    }

    /// Every worktree of one repository, with its status. A repository-wide call each for the
    /// list, the default branch, the branches' upstream counts and dates, and which branches
    /// are merged; then `git status` once per worktree, which is the only per-row cost.
    /// No disk size: `du` walks every file of every worktree, about 126 GB under helm's alone.
    func worktrees(
        in repository: GitCommonDir, statusOfALoneCheckout: Bool
    ) async throws
        -> [Worktree]
    {
        let commonDir = repository.path
        let listing = try await runGit(["-C", commonDir, "worktree", "list", "--porcelain"])
        let records = try Self.parsePorcelain(listing)
        let defaultBranch = await resolveDefaultBranch(in: commonDir)
        let branches = await branchFacts(in: commonDir)
        let merged = await mergedBranches(into: defaultBranch, in: commonDir)

        var worktrees: [Worktree] = []
        for (index, record) in records.enumerated() {
            let exists = FileManager.default.fileExists(atPath: record.path)
            let facts = record.branch.flatMap { branches[$0] }
            let readsStatus =
                exists && !record.isBare && (records.count > 1 || statusOfALoneCheckout)
            let dirty = readsStatus ? await isDirty(record.path) : nil
            worktrees.append(
                Worktree(
                    record: record,
                    kind: .classify(branch: record.branchName),
                    status: WorktreeStatus(
                        isDirty: dirty, tracking: facts?.tracking,
                        lastCommitAt: facts?.committedAt),
                    mergedState: Self.mergedState(of: record.branch, in: merged),
                    isMain: index == 0,
                    exists: exists))
        }
        return worktrees
    }

    func remove(path: String, in repository: GitCommonDir) async throws {
        _ = try await runGit(["-C", repository.path, "worktree", "remove", path])
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

    private func resolveDefaultBranch(in commonDir: String) async -> String? {
        guard
            let text = try? await runGit([
                "-C", commonDir, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD",
            ])
        else { return nil }
        let branch = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    struct BranchFacts: Equatable {
        let tracking: WorktreeTracking?
        let committedAt: Date?
    }

    /// Every local branch's upstream counts and tip date, in one `for-each-ref`. A failure
    /// leaves every row's counts and age unknown, never the listing.
    private func branchFacts(in commonDir: String) async -> [String: BranchFacts] {
        guard
            let text = try? await runGit([
                "-C", commonDir, "for-each-ref", "refs/heads",
                "--format=%(refname)%00%(upstream)%00%(upstream:track,nobracket)%00%(committerdate:unix)",
            ])
        else { return [:] }
        return Self.parseBranchFacts(text)
    }

    static func parseBranchFacts(_ text: String) -> [String: BranchFacts] {
        var facts: [String: BranchFacts] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            facts[String(fields[0])] = BranchFacts(
                tracking: fields[1].isEmpty ? nil : WorktreeTracking.parse(String(fields[2])),
                committedAt: TimeInterval(fields[3]).map(Date.init(timeIntervalSince1970:)))
        }
        return facts
    }

    /// The local branches whose tips the default branch reaches: Git's "merged", never a pull
    /// request's. nil when there is no default branch or git refused, so no row is cleanable.
    private func mergedBranches(
        into defaultBranch: String?, in commonDir: String
    ) async
        -> Set<String>?
    {
        guard let defaultBranch,
            let text = try? await runGit([
                "-C", commonDir, "for-each-ref", "--merged", defaultBranch,
                "--format=%(refname)", "refs/heads",
            ])
        else { return nil }
        return Set(text.split(separator: "\n").map(String.init))
    }

    static func mergedState(of branch: String?, in merged: Set<String>?) -> WorktreeMergedState {
        guard let branch, let merged else { return .unknown }
        return merged.contains(branch) ? .merged : .unmerged
    }

    /// `--no-optional-locks` so reading a worktree never takes its index lock from under an
    /// agent working in it. nil when git could not say.
    private func isDirty(_ path: String) async -> Bool? {
        guard
            let text = try? await runGit([
                "--no-optional-locks", "-C", path, "status", "--porcelain",
            ])
        else { return nil }
        return !text.isEmpty
    }

    private func runGit(_ arguments: [String]) async throws -> String {
        let executableArguments =
            gitExecutable == "/usr/bin/env" ? ["git"] + arguments : [gitExecutable] + arguments
        return try await run(
            arguments: executableArguments,
            commandName: (["git"] + arguments).joined(separator: " "))
    }

    private func run(arguments: [String], commandName: String) async throws -> String {
        let result: Subprocess.Result
        do {
            result = try await Subprocess.run(
                arguments, environment: environment, timeout: timeout)
        } catch let failure as Subprocess.Failure {
            let reason: WorktreeCLIError.Reason =
                switch failure {
                case let .captureUnavailable(why):
                    .launchFailed(why ?? "could not create temporary command capture")
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
        return String(decoding: result.stdout, as: UTF8.self)
    }
}
