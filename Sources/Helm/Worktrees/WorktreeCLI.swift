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
    /// What removing `worktree` would lose, read now.
    func loss(of worktree: Worktree, in repository: GitCommonDir) async -> WorktreeLoss
    /// Remove a git-owned worktree the operator confirmed, knowing `loss`.
    func remove(
        _ worktree: Worktree, in repository: GitCommonDir, knowing loss: WorktreeLoss
    ) async throws
    /// Hand an Archon-owned worktree to `archon complete`; answers what Archon printed.
    func archonComplete(branch: String, home: String?, main: String) async throws -> String
    /// Add a worktree for `branch` at the repository's conventional place; answers its path.
    func create(
        branch: String, in repository: GitCommonDir, main: String
    ) async throws
        -> String
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
    /// Where `~/.bun/bin` is looked for when `archon` is run, as `ArchonCLI` does. A test
    /// points it at a scratch folder so its fake `archon` is the one found, never the real one.
    let homeDirectory: String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        gitExecutable: String = "/usr/bin/env",
        timeout: Duration = WorktreeCLI.defaultTimeout,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.environment = environment
        self.gitExecutable = gitExecutable
        self.timeout = timeout
        self.homeDirectory = homeDirectory
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
                    status: WorktreeStatus(
                        isDirty: dirty, tracking: facts?.tracking,
                        lastCommitAt: facts?.committedAt),
                    mergedState: Self.mergedState(of: record.branch, in: merged),
                    isMain: index == 0,
                    exists: exists))
        }
        return worktrees
    }

    // MARK: Changing

    func loss(of worktree: Worktree, in repository: GitCommonDir) async -> WorktreeLoss {
        let commonDir = repository.path
        let path = worktree.record.path
        let uncommitted: Int?
        if worktree.exists {
            uncommitted =
                (try? await runGit([
                    "--no-optional-locks", "-C", path, "status", "--porcelain",
                ]))
                .map { $0.split(separator: "\n").count }
        } else {
            uncommitted = 0
        }
        let defaultBranch = await resolveDefaultBranch(in: commonDir)
        let tip = worktree.record.branch ?? worktree.record.head
        var unmerged: Int?
        if let defaultBranch, let tip {
            unmerged =
                (try? await runGit([
                    "-C", commonDir, "rev-list", "--count", "\(defaultBranch)..\(tip)",
                ]))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return WorktreeLoss(
            uncommittedFiles: uncommitted, unmergedCommits: unmerged,
            branch: worktree.record.branchName, defaultBranch: defaultBranch)
    }

    /// `git worktree remove`, with `--force` only when the operator confirmed losing
    /// uncommitted files; or, for a worktree whose folder is already gone, `prune`, which is all
    /// git's record of it needs (and clears any other missing worktree's record too); then the branch, only when the default branch still reaches every commit on it —
    /// checked again here, not trusted from the confirmation.
    func remove(
        _ worktree: Worktree, in repository: GitCommonDir, knowing loss: WorktreeLoss
    ) async throws {
        let commonDir = repository.path
        if worktree.exists {
            let force = (loss.uncommittedFiles ?? 0) > 0 ? ["--force"] : []
            _ = try await runGit(
                ["-C", commonDir, "worktree", "remove"] + force + [worktree.record.path])
        } else {
            _ = try await runGit(["-C", commonDir, "worktree", "prune"])
        }
        guard loss.deletesBranch, let branch = worktree.record.branch,
            let defaultBranch = await resolveDefaultBranch(in: commonDir)
        else { return }
        _ = try await runGit([
            "-C", commonDir, "merge-base", "--is-ancestor", branch, defaultBranch,
        ])
        _ = try await runGit([
            "-C", commonDir, "branch", "-D", worktree.record.branchName ?? branch,
        ])
    }

    /// Archon's own cleanup, in the Archon home the worktree lives under. `archon complete`
    /// exits 0 whether it removed the worktree, refused, or found nothing, so its words are
    /// answered for the caller to show when git says the worktree is still there.
    func archonComplete(branch: String, home: String?, main: String) async throws -> String {
        var environment = ArchonCLI.developmentEnvironment(
            inherited: self.environment, homeDirectory: homeDirectory)
        if let home { environment["ARCHON_HOME"] = home }
        let command = "archon complete \(branch)"
        let result: Subprocess.Result
        do {
            result = try await Subprocess.run(
                ["archon", "complete", branch], cwd: main, environment: environment,
                timeout: .seconds(120))
        } catch let failure as Subprocess.Failure {
            throw WorktreeCLIError(
                command: command, reason: Self.reason(for: failure, timeout: .seconds(120)))
        }
        let text = [result.stdout, result.stderr]
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            throw WorktreeCLIError(
                command: command,
                reason: .nonzeroExit(
                    status: result.status,
                    stderr: result.stderrSnippet(limit: Self.errorSnippetLimit)))
        }
        return text
    }

    func create(
        branch: String, in repository: GitCommonDir, main: String
    ) async throws
        -> String
    {
        _ = try await runGit(["check-ref-format", "--branch", branch])
        let path = WorktreePlace.path(
            for: branch, main: main,
            keepsWorktreesInside: await keepsWorktreesInside(main))
        guard !FileManager.default.fileExists(atPath: path) else {
            throw WorktreeCLIError(
                command: "git worktree add \(path)",
                reason: .malformedOutput("\(path) already exists"))
        }
        let source = await branchSource(branch, in: repository.path)
        let arguments: [String] =
            switch source {
            case .local: [path, branch]
            case let .remote(ref): ["--track", "-b", branch, path, ref]
            case let .new(base): ["--no-track", "-b", branch, path, base]
            }
        _ = try await runGit(["-C", main, "worktree", "add"] + arguments)
        return path
    }

    func branchSource(_ branch: String, in commonDir: String) async -> WorktreeBranchSource {
        if await refExists("refs/heads/\(branch)", in: commonDir) { return .local }
        if await refExists("refs/remotes/origin/\(branch)", in: commonDir) {
            return .remote("origin/\(branch)")
        }
        return .new(from: await resolveDefaultBranch(in: commonDir) ?? "HEAD")
    }

    private func refExists(_ ref: String, in commonDir: String) async -> Bool {
        (try? await runGit(["-C", commonDir, "show-ref", "--verify", "--quiet", ref])) != nil
    }

    /// The repository keeps worktrees in `.worktrees` when that folder exists or git ignores it.
    private func keepsWorktreesInside(_ main: String) async -> Bool {
        let folder = URL(fileURLWithPath: main).appendingPathComponent(".worktrees").path
        if FileManager.default.fileExists(atPath: folder) { return true }
        return (try? await runGit(["-C", main, "check-ignore", "-q", ".worktrees/"])) != nil
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
            throw WorktreeCLIError(
                command: commandName, reason: Self.reason(for: failure, timeout: timeout))
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

    private static func reason(
        for failure: Subprocess.Failure, timeout: Duration
    )
        -> WorktreeCLIError.Reason
    {
        switch failure {
        case let .captureUnavailable(why):
            .launchFailed(why ?? "could not create temporary command capture")
        case let .launchFailed(why): .launchFailed(why)
        case .timedOut: .timedOut(after: timeout)
        case let .unreadableOutput(why): .unreadableOutput(why)
        }
    }
}
