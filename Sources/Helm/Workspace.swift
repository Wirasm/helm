import CryptoKit
import Foundation

/// A folder helm has open — the operating context that replaced the engine's
/// registry `project`. Identity is the PATH, deliberately: a main checkout and one
/// of its worktrees are two workspaces, which a registry keyed by unique name could
/// never express. Nothing is registered anywhere; opening the folder is the whole
/// ceremony, and closing one is a purely local list removal.
struct Workspace: Hashable, Identifiable, Codable {
    /// Absolute, tilde-expanded, no trailing slash.
    let path: String

    var id: String { path }

    /// The folder's basename — what the sidebar row shows in bold.
    var name: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    init(path: String) {
        self.path = Self.normalized(path)
    }

    init(url: URL) {
        self.init(path: url.path)
    }

    /// A trailing slash and a leading `~` are display noise, not identity: two
    /// values differing only by one would be two sidebar rows for one folder.
    /// Symlinks are deliberately NOT resolved here — the path the operator chose is
    /// the path helm shows and filters on; only store resolution needs the real one.
    static func normalized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var trimmed = Substring(expanded)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    // Coded as a bare path string, so the persisted blob is a plain ["/a", "/b"] —
    // and, unlike the synthesized conformance, decoding runs through the normaliser.
    init(from decoder: any Decoder) throws {
        self.init(path: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }
}

// MARK: - Persistence

/// The open-workspace list as it survives a relaunch. `@AppStorage` cannot hold an
/// array, so the list lives as a JSON string under `helmWorkspaces` and the current
/// selection as a bare path under `helmSelectedWorkspace` — both in the same
/// `UserDefaults` an `@AppStorage` view property would use.
enum WorkspacePersistence {
    static let listKey = "helmWorkspaces"
    static let selectionKey = "helmSelectedWorkspace"

    /// A missing or corrupt blob is an empty list — never a crash, never a partial
    /// list: the operator reopens the folders, which costs one ⌘⇧O each.
    static func load(from defaults: UserDefaults) -> [Workspace] {
        guard
            let raw = defaults.string(forKey: listKey),
            let decoded = try? JSONDecoder().decode([Workspace].self, from: Data(raw.utf8))
        else { return [] }
        return decoded
    }

    /// Encoding an array of strings cannot fail; the `try?` exists only because the
    /// signature says it can, and dropping a save is still better than trapping.
    static func save(_ workspaces: [Workspace], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: listKey)
    }

    /// The remembered selection, but only if it is still an open workspace.
    static func loadSelection(from defaults: UserDefaults, in workspaces: [Workspace]) -> Workspace?
    {
        guard let path = defaults.string(forKey: selectionKey) else { return nil }
        let remembered = Workspace(path: path)
        return workspaces.contains(remembered) ? remembered : nil
    }

    static func saveSelection(_ workspace: Workspace?, to defaults: UserDefaults) {
        if let workspace {
            defaults.set(workspace.path, forKey: selectionKey)
        } else {
            defaults.removeObject(forKey: selectionKey)
        }
    }
}

// MARK: - Artifact-store resolution

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
    /// Shells out to git, so callers keep it off the render path (KildStore resolves
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
