import CryptoKit
import Foundation

/// A workspace folder → the `~/.prp/<key>/` store its artifacts live in.
///
/// prp keys a store by the repo's MAIN checkout (`git rev-parse --git-common-dir`),
/// so a worktree and the checkout it came from share ONE store. That is prp's
/// contract, not an accident: the plans and reviews of a branch belong to the
/// project, not to the directory that happens to hold the branch.
///
/// Matching beats deriving. An existing store already records its root in
/// `project.json`'s `"path"`, so the first pass is a string comparison with no
/// algorithm to drift from prp's; the derived key is the fallback for a store whose
/// registration is unreadable.
enum WorkspaceStore {
    /// The store `path` belongs to, among the discovered ones — nil when nothing has
    /// written artifacts for this repo yet.
    static func store(for path: String, in stores: [ArtifactStore]) -> ArtifactStore? {
        store(forRoot: repositoryRoot(for: path), in: stores)
    }

    /// The matching half, pure: no subprocess, so a view may call it per open.
    static func store(forRoot root: String, in stores: [ArtifactStore]) -> ArtifactStore? {
        if let registered = stores.first(where: { $0.projectPath == root }) { return registered }
        let derived = derivedKey(forRoot: root)
        return stores.first { $0.key == derived }
    }

    /// prp's project root for a folder: `git rev-parse --path-format=absolute
    /// --git-common-dir` minus a trailing `/.git`, symlinks resolved. From inside a
    /// worktree that is the MAIN checkout — the reason two workspaces on one repo
    /// resolve to one store. A folder that is no repo at all is its own root.
    ///
    /// Shells out to git, so callers keep it off the render path (resolved
    /// once per workspace selection, on a detached task).
    static func repositoryRoot(for path: String) -> String {
        let gitDir = git(["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard let gitDir, !gitDir.isEmpty else { return resolved(path) }
        return resolved(gitDir.hasSuffix("/.git") ? String(gitDir.dropLast(5)) : gitDir)
    }

    /// prp's store key for an already-resolved root: `<slug>-<hash8>`.
    static func derivedKey(forRoot root: String) -> String {
        "\(slug(forRoot: root))-\(blobHash(of: root).prefix(8))"
    }

    /// prp's slug: the lowercased basename with every run of non-`[a-z0-9]` collapsed
    /// to one `-`, ends trimmed. An entirely non-alphanumeric basename yields
    /// "project", exactly as prp's `or "project"` does.
    static func slug(forRoot root: String) -> String {
        let basename = (root as NSString).lastPathComponent.lowercased()
        var slug = ""
        var pendingSeparator = false
        for scalar in basename.unicodeScalars {
            let isSlugChar = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            guard isSlugChar else {
                pendingSeparator = true
                continue
            }
            if pendingSeparator, !slug.isEmpty { slug.append("-") }
            pendingSeparator = false
            slug.unicodeScalars.append(scalar)
        }
        return slug.isEmpty ? "project" : slug
    }

    /// `git hash-object --stdin` over `content`, computed rather than spawned: a git
    /// blob id is SHA-1 over `blob <byte-count>\0<content>`, a fixed on-disk format.
    /// WorkspaceTests pins this against the real `git hash-object`.
    static func blobHash(of content: String) -> String {
        let bytes = Data(content.utf8)
        var payload = Data("blob \(bytes.count)\0".utf8)
        payload.append(bytes)
        return Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    /// `pwd -P` semantics, matching prp's `Path.resolve()`: symlinks collapsed for a
    /// folder that exists, the tilde-expanded path as-is for one that does not.
    private static func resolved(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let real = realpath(expanded, nil) else { return expanded }
        defer { free(real) }
        return String(cString: real)
    }

    /// git's stdout, trimmed — nil on any non-zero exit (not a repo, no git, gone
    /// directory), which every caller treats as "no repo here", never as an error.
    /// stdin and stderr are /dev/null so git can never block on a prompt.
    private static func git(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain before waiting: a full pipe buffer would deadlock the other order.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
