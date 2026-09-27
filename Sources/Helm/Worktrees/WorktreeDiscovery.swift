import Foundation

/// Which git repositories the Worktrees drawer lists (#382): every one the operator works in,
/// found by reading the filesystem. It starts no process, so a scan of a few hundred folders
/// costs milliseconds, and git is still the only source of what a repository holds.
///
/// Three places, deduplicated by the repository's common git directory:
///
/// - the bench's workspaces, which are listed even when they have no linked worktree;
/// - `<home>/Projects`, down to `projectDepth` folders, skipping build output and dependencies
///   and never descending into a repository once found;
/// - Archon's worktrees, `<home>/.archon*/workspaces/<owner>/<repo>/worktrees/…`, which lead
///   back to the repository each was made from.
///
/// `home` is the operator's home unless `HELM_WORKTREES_HOME` names another, which is how an
/// isolated instance and the tests list scratch repositories instead of his.
struct WorktreeDiscovery: Sendable {
    let home: URL
    static let projectDepth = 4
    static let skipped: Set<String> = [
        "node_modules", ".build", ".worktrees", "target", ".venv", "venv", "dist", "build",
        "Pods", "DerivedData",
    ]

    init(home: URL) {
        self.home = home
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let override = environment["HELM_WORKTREES_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        self.init(home: URL(fileURLWithPath: override ?? NSHomeDirectory(), isDirectory: true))
    }

    struct Found: Equatable, Sendable {
        let commonDir: GitCommonDir
        /// Some bench workspace is in this repository.
        let isWorkspace: Bool
    }

    /// Every repository, workspaces' first, then the rest by path.
    func repositories(workspaces: [String]) -> [Found] {
        var found: [String: Bool] = [:]
        for path in workspaces {
            if let dir = Self.commonDir(containing: URL(fileURLWithPath: path)) {
                found[dir] = true
            }
        }
        for dir in projects() + archonWorktrees() where found[dir] == nil {
            found[dir] = false
        }
        return found.map { Found(commonDir: GitCommonDir($0.key), isWorkspace: $0.value) }
            .sorted {
                ($0.isWorkspace ? 0 : 1, $0.commonDir) < ($1.isWorkspace ? 0 : 1, $1.commonDir)
            }
    }

    private func projects() -> [String] {
        var found: [String] = []
        var level = [home.appendingPathComponent("Projects", isDirectory: true)]
        for _ in 0...Self.projectDepth where !level.isEmpty {
            var next: [URL] = []
            for folder in level {
                if let dir = Self.commonDir(of: folder) {
                    found.append(dir)
                } else {
                    next += Self.subfolders(of: folder)
                }
            }
            level = next
        }
        return found
    }

    private func archonWorktrees() -> [String] {
        let homes = Self.subfolders(of: home, includingHidden: true)
            .filter { $0.lastPathComponent.hasPrefix(".archon") }
        let worktreeRoots = homes.flatMap { archonHome in
            Self.subfolders(of: archonHome.appendingPathComponent("workspaces"))
                .flatMap { Self.subfolders(of: $0) }
                .map { $0.appendingPathComponent("worktrees") }
        }
        // Archon nests a worktree one or two folders down: `worktrees/<prefix>/<name>`.
        return worktreeRoots.flatMap { root in
            Self.subfolders(of: root).flatMap { child in
                Self.commonDir(of: child).map { [$0] }
                    ?? Self.subfolders(of: child).compactMap { Self.commonDir(of: $0) }
            }
        }
    }

    // MARK: Reading a checkout

    /// The common git directory of the checkout at `folder` or of any folder above it.
    static func commonDir(containing folder: URL) -> String? {
        var folder = folder.standardizedFileURL
        while true {
            if let dir = commonDir(of: folder) { return dir }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return nil }
            folder = parent
        }
    }

    /// The common git directory of the checkout whose root is `folder`, or nil when `folder`
    /// is not one. A main checkout's `.git` is a directory and is the answer. A linked
    /// worktree's `.git` is a file, `gitdir: <repo>/.git/worktrees/<name>`, and that directory
    /// names the common one in its `commondir` file; without one (a submodule) it is its own.
    static func commonDir(of folder: URL) -> String? {
        let dotGit = folder.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory)
        else { return nil }
        if isDirectory.boolValue { return canonical(dotGit) }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
            let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ")
        else { return nil }
        let gitDir = URL(
            fileURLWithPath: String(line.dropFirst("gitdir: ".count)), relativeTo: folder)
        guard
            let common = try? String(
                contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8)
        else { return canonical(gitDir) }
        return canonical(
            URL(
                fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines),
                relativeTo: gitDir.appendingPathComponent("", isDirectory: true)))
    }

    /// Resolved through symlinks, so one repository reached two ways is one entry.
    private static func canonical(_ url: URL) -> String {
        url.absoluteURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Real folders only: no symlinks (a symlinked checkout is found where it lives), no
    /// hidden ones unless asked, and none of `skipped`.
    private static func subfolders(of folder: URL, includingHidden: Bool = false) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let options: FileManager.DirectoryEnumerationOptions =
            includingHidden ? [] : [.skipsHiddenFiles]
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: options)
        else { return [] }
        return children.filter { child in
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                values.isDirectory == true, values.isSymbolicLink != true
            else { return false }
            return !skipped.contains(child.lastPathComponent)
        }
    }
}
