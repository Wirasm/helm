import AppKit
import Foundation

/// Where a finished run's work went, read off the worktree Archon cut for it.
///
/// **The branch is not the directory's basename, and getting that wrong fails silently.**
/// Archon builds the path by joining its base with the branch —
/// `join(base, branchName)` in `packages/isolation/src/providers/worktree.ts` — and its branch
/// names carry a slash (`archon/task-…`, `archon/issue-…`, `archon/review-…`), so git nests the
/// directory to match. Taking the last component alone yields `task-…`, which is not a branch
/// that exists, and every lookup then finds nothing with nothing on screen to say why.
/// Verified against this machine's own `git worktree list`:
///
/// ```
/// …/worktrees/archon/task-x-1785773886177  [archon/task-x-1785773886177]
/// ```
///
/// A same-repo PR run is what stops this being a "strip the `archon/` prefix" rule instead: it
/// runs on the pull request's own branch, which carries no prefix at all. So the rule is
/// *everything after `worktrees`*, whatever shape it has.
struct ArchonRunLink: Equatable, Sendable {
    let owner: String
    let repo: String
    let branch: String

    /// What `gh -R` wants.
    var repository: String { "\(owner)/\(repo)" }

    /// The branch's page, which is where a run that produced no pull request still has
    /// something to show — a failed run whose only failure was `create-pr` has all its work
    /// here.
    var branchURL: URL? {
        URL(string: "https://github.com/\(repository)/tree/\(branch)")
    }

    /// Parses `~/.archon/workspaces/<owner>/<repo>/worktrees/<branch…>`, the layout
    /// `getWorktreeBase` resolves to by default (`packages/git/src/worktree.ts`).
    ///
    /// Returns nil rather than guessing for the two shapes that carry no branch: a run
    /// launched with `--no-worktree`, whose `working_path` is just the checkout, and a
    /// repo-local worktree base, which names no owner. A row with no link is not a button —
    /// fabricating a URL for it would send the operator somewhere that does not exist.
    static func parse(workingPath: String?) -> ArchonRunLink? {
        guard let workingPath, !workingPath.isEmpty else { return nil }
        let parts = workingPath.split(separator: "/").map(String.init)
        guard let worktrees = parts.lastIndex(of: "worktrees"), worktrees + 1 < parts.count
        else { return nil }
        let branch = parts[(worktrees + 1)...].joined(separator: "/")
        guard let workspaces = parts[..<worktrees].lastIndex(of: "workspaces"),
            workspaces + 2 < worktrees
        else { return nil }
        return ArchonRunLink(
            owner: parts[workspaces + 1], repo: parts[workspaces + 2], branch: branch)
    }
}

/// What a click on a finished run does, behind one closure so the rail can be tested without
/// spawning anything.
///
/// **Lazily, and only on click** — the alternative is asking GitHub about every finished run on
/// every 2s poll, which is a rate limit and a lot of subprocesses for a question nobody asked.
struct ArchonRunOpener: Sendable {
    var open: @Sendable (ArchonRun) async -> Void

    static let live = ArchonRunOpener { run in
        guard let url = await ArchonRunOpener.destination(for: run) else { return }
        await MainActor.run { NSWorkspace.shared.open(url) }
    }

    /// The pull request if there is one, else the branch it would be opened from.
    ///
    /// `gh pr view --head <branch>` — the obvious spelling, and what #151 proposed — **is not a
    /// command**: `--head` belongs to `gh pr list`, and `gh pr view <branch>` errors rather than
    /// falling back to the branch when no pull request exists. So it is a list to find the URL,
    /// then a plain open.
    static func destination(for run: ArchonRun) async -> URL? {
        guard let workingPath = run.workingPath,
            let link = ArchonRunLink.parse(workingPath: workingPath)
        else { return nil }
        // The worktree is the authority on its own branch while it exists; the path is the
        // fallback for after Archon's cleanup has removed it. A detached HEAD answers `HEAD`,
        // which is not a branch anyone can open — the path's answer is better than that.
        let resolved = await capture([
            "git", "-C", workingPath, "rev-parse", "--abbrev-ref", "HEAD",
        ])
        let branch = (resolved == "HEAD" ? nil : resolved) ?? link.branch
        guard !branch.isEmpty else { return link.branchURL }
        if let pullRequest = await pullRequestURL(repository: link.repository, branch: branch) {
            return pullRequest
        }
        return URL(string: "https://github.com/\(link.repository)/tree/\(branch)")
    }

    private static func pullRequestURL(repository: String, branch: String) async -> URL? {
        let json = await capture([
            "gh", "pr", "list", "-R", repository, "--head", branch,
            "--state", "all", "--json", "url", "--limit", "1",
        ])
        guard let json, let data = json.data(using: .utf8),
            let rows = try? JSONDecoder().decode([[String: String]].self, from: data),
            let url = rows.first?["url"]
        else { return nil }
        return URL(string: url)
    }

    /// Homebrew's bin ahead of the inherited `PATH`, for the same reason
    /// `ArchonCLI.developmentEnvironment` puts `~/.bun/bin` there: `gh` is a Homebrew install
    /// and a bundled app inherits launchd's `PATH`, which has never heard of it. `git` needs no
    /// help — it is at `/usr/bin` — but goes through the same environment so there is one
    /// answer to "what did the subprocess see".
    static func environment(inherited: [String: String]) -> [String: String] {
        var environment = inherited
        let inheritedPath = inherited["PATH"].flatMap { $0.isEmpty ? nil : $0 }
        environment["PATH"] =
            (["/opt/homebrew/bin", "/usr/local/bin"] + [inheritedPath].compactMap { $0 })
            .joined(separator: ":")
        return environment
    }

    /// The lightweight subprocess shape — `WorkspaceBar.resolveBranch`'s, not `ArchonCLI`'s.
    /// A click does not need a timeout watchdog and a SIGTERM path; it needs to be off the main
    /// actor and to give up quietly.
    private static func capture(_ arguments: [String]) async -> String? {
        await Task.detached { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.environment = Self.environment(
                inherited: ProcessInfo.processInfo.environment)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.value
    }
}
