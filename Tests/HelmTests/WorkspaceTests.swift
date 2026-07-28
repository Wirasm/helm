import Foundation
import XCTest

@testable import Helm

/// The workspace model and — the risky part — its `~/.prp` store resolution, which
/// must agree with prp's canonical resolver defined in ANOTHER repo
/// (`prp/.claude/skills/prp-loop/scripts/prp_loop.py`). Two defences against drift:
/// a golden key for a known root, and differential tests that run prp's own shell
/// pipeline and compare it to the Swift port over real git repos.
final class WorkspaceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-workspace-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - The type

    func testPathIsIdentityAndNameIsTheBasename() {
        let workspace = Workspace(path: "/Users/dev/Projects/sild/helm")
        XCTAssertEqual(workspace.id, "/Users/dev/Projects/sild/helm")
        XCTAssertEqual(workspace.name, "helm")

        // Two checkouts of one repo are two DISTINCT workspaces — the thing a
        // unique-name registry could not express.
        let worktree = Workspace(path: "/Users/dev/Projects/sild/helm/.worktrees/fix")
        XCTAssertNotEqual(workspace, worktree)
        XCTAssertEqual(worktree.name, "fix")
    }

    func testConstructionNormalisesTrailingSlashesAndTilde() {
        XCTAssertEqual(Workspace(path: "/a/b/").path, "/a/b")
        XCTAssertEqual(Workspace(path: "/a/b///").path, "/a/b")
        XCTAssertEqual(Workspace(path: "/").path, "/")
        XCTAssertEqual(
            Workspace(path: "~/code").path,
            FileManager.default.homeDirectoryForCurrentUser.path + "/code"
        )

        // Opening the same folder twice must be ONE list entry.
        XCTAssertEqual(Workspace(path: "/a/b/"), Workspace(path: "/a/b"))
        XCTAssertEqual(Set([Workspace(path: "/a/b/"), Workspace(path: "/a/b")]).count, 1)
    }

    func testCodingIsABarePathAndDecodingRenormalises() throws {
        let encoded = try JSONEncoder().encode([Workspace(path: "/a/b"), Workspace(path: "/c")])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["\/a\/b","\/c"]"#)

        // A hand-written or older blob with a trailing slash still lands normalised.
        let decoded = try JSONDecoder().decode([Workspace].self, from: Data(#"["/a/b/"]"#.utf8))
        XCTAssertEqual(decoded, [Workspace(path: "/a/b")])
    }

    // MARK: - Persistence

    func testWorkspaceListRoundTripsThroughDefaults() throws {
        let defaults = try isolatedDefaults()
        let workspaces = [Workspace(path: "/a/b"), Workspace(path: "/a/b/.worktrees/fix")]

        WorkspacePersistence.save(workspaces, to: defaults)
        XCTAssertEqual(WorkspacePersistence.load(from: defaults), workspaces)
        // Stored as a plain string under the @AppStorage-compatible key.
        XCTAssertNotNil(defaults.string(forKey: "helmWorkspaces"))
    }

    func testCorruptOrMissingBlobLoadsAsEmptyList() throws {
        let defaults = try isolatedDefaults()
        XCTAssertEqual(WorkspacePersistence.load(from: defaults), [])

        defaults.set("{not json", forKey: WorkspacePersistence.listKey)
        XCTAssertEqual(WorkspacePersistence.load(from: defaults), [])
    }

    func testSelectionPersistsOnlyWhileItIsStillOpen() throws {
        let defaults = try isolatedDefaults()
        let open = [Workspace(path: "/a/b")]

        WorkspacePersistence.saveSelection(open[0], to: defaults)
        XCTAssertEqual(WorkspacePersistence.loadSelection(from: defaults, in: open), open[0])

        // A remembered selection that is no longer in the list falls back to All.
        XCTAssertNil(WorkspacePersistence.loadSelection(from: defaults, in: []))

        WorkspacePersistence.saveSelection(nil, to: defaults)
        XCTAssertNil(WorkspacePersistence.loadSelection(from: defaults, in: open))
    }

    // MARK: - Store key: golden value + differential against prp

    /// THE golden value. helm's own repo root resolves to the store this plan was
    /// written into, `~/.prp/helm-3ec376fc`. A pure function of the literal path, so
    /// it pins slug + hash composition without depending on a checkout location.
    func testDerivedKeyMatchesTheRealHelmStore() {
        XCTAssertEqual(
            WorkspaceStore.derivedKey(forRoot: "/Users/rasmus/Projects/mine/sild/helm"),
            "helm-3ec376fc"
        )
    }

    /// The computed blob id must be byte-identical to `git hash-object --stdin` —
    /// the half of prp's key helm reimplements instead of spawning.
    func testBlobHashMatchesGitHashObject() throws {
        for content in [
            "/Users/rasmus/Projects/mine/sild/helm",
            "/tmp/a b/c",
            "/tmp/ünïcøde",
            "",
        ] {
            XCTAssertEqual(
                WorkspaceStore.blobHash(of: content),
                try gitHashObject(content),
                "blob id drifted for \(content.debugDescription)"
            )
        }
    }

    func testSlugMirrorsPrpSlugification() {
        XCTAssertEqual(WorkspaceStore.slug(forRoot: "/x/helm"), "helm")
        XCTAssertEqual(WorkspaceStore.slug(forRoot: "/x/My Project"), "my-project")
        XCTAssertEqual(WorkspaceStore.slug(forRoot: "/x/a__b--c"), "a-b-c")
        XCTAssertEqual(WorkspaceStore.slug(forRoot: "/x/-lead-and-trail-"), "lead-and-trail")
        XCTAssertEqual(WorkspaceStore.slug(forRoot: "/x/ünïcøde"), "n-c-de")
        // prp's `or "project"` for a basename with nothing to keep.
        XCTAssertEqual(WorkspaceStore.slug(forRoot: "/x/---"), "project")
    }

    /// A path with spaces and non-ASCII, end to end against prp's own pipeline.
    func testStoreKeyMatchesPrpForAwkwardPaths() throws {
        for name in ["My Project", "ünïcøde repo", "UPPER_Case"] {
            let dir = tempRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let root = WorkspaceStore.repositoryRoot(for: dir.path)
            XCTAssertEqual(
                WorkspaceStore.derivedKey(forRoot: root),
                try canonicalStoreKey(runIn: dir.path),
                "store key drifted from prp for \(name)"
            )
        }
    }

    // MARK: - Store key: real repos and worktrees

    /// The load-bearing behaviour: a worktree resolves to its MAIN checkout, so two
    /// workspaces on one repo share one `~/.prp` store. Intended, not a bug.
    func testWorktreeResolvesToItsMainCheckoutsRootAndKey() throws {
        let main = try makeRepo(named: "repo")
        let worktree = try addWorktree(named: "fix", to: main)

        let mainRoot = WorkspaceStore.repositoryRoot(for: main.path)
        let worktreeRoot = WorkspaceStore.repositoryRoot(for: worktree.path)

        XCTAssertEqual(worktreeRoot, mainRoot)
        XCTAssertFalse(worktreeRoot.contains("/fix"), "resolved to the worktree, not the checkout")
        XCTAssertEqual(
            WorkspaceStore.derivedKey(forRoot: worktreeRoot),
            WorkspaceStore.derivedKey(forRoot: mainRoot)
        )
        // …and both agree with prp's own resolver run from each directory.
        XCTAssertEqual(
            WorkspaceStore.derivedKey(forRoot: mainRoot), try canonicalStoreKey(runIn: main.path)
        )
        XCTAssertEqual(
            WorkspaceStore.derivedKey(forRoot: worktreeRoot),
            try canonicalStoreKey(runIn: worktree.path)
        )
    }

    /// A subdirectory of a repo is still the repo — prp keys by root, not by cwd.
    func testSubdirectoryResolvesToTheRepoRoot() throws {
        let main = try makeRepo(named: "repo")
        let sub = main.appendingPathComponent("Sources/Deep")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        XCTAssertEqual(
            WorkspaceStore.repositoryRoot(for: sub.path),
            WorkspaceStore.repositoryRoot(for: main.path)
        )
    }

    /// A plain folder is its own root: no git, no error, still a usable key. The root
    /// is `pwd -P` — symlinks collapsed exactly as prp's `Path.resolve()` does, which
    /// matters under /var/folders where the temp dir is itself a symlink.
    func testNonRepoFolderIsItsOwnRoot() throws {
        let plain = tempRoot.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let root = WorkspaceStore.repositoryRoot(for: plain.path)
        XCTAssertEqual(root, try run("/bin/sh", ["-c", #"cd "$1" && pwd -P"#, "sh", plain.path]))
        XCTAssertEqual(
            WorkspaceStore.derivedKey(forRoot: root), try canonicalStoreKey(runIn: plain.path))
        XCTAssertTrue(WorkspaceStore.derivedKey(forRoot: root).hasPrefix("plain-"))
    }

    func testMissingFolderStillYieldsAKeyRatherThanCrashing() {
        let gone = tempRoot.appendingPathComponent("never-existed").path
        XCTAssertEqual(WorkspaceStore.repositoryRoot(for: gone), gone)
    }

    /// helm's own checkout — proof that running from a worktree (this branch is one)
    /// still lands on the main checkout's store, `helm-3ec376fc`.
    func testThisCheckoutResolvesToTheHelmStore() {
        let here = (#filePath as NSString).deletingLastPathComponent
        let root = WorkspaceStore.repositoryRoot(for: here)

        XCTAssertFalse(root.contains("/.worktrees/"), "a worktree must resolve to its checkout")
        XCTAssertEqual((root as NSString).lastPathComponent, "helm")
        XCTAssertEqual(WorkspaceStore.derivedKey(forRoot: root), "helm-3ec376fc")
    }

    // MARK: - Store matching

    func testStoreMatchesOnProjectJSONPathBeforeDerivingAnything() {
        let stores = [
            store(key: "other-11111111", path: "/x/other"),
            // A key that could never be derived from the root — proving the match
            // came from project.json's "path", not from the algorithm.
            store(key: "renamed-by-hand", path: "/x/helm"),
        ]
        XCTAssertEqual(WorkspaceStore.store(forRoot: "/x/helm", in: stores)?.key, "renamed-by-hand")
    }

    func testStoreFallsBackToTheDerivedKeyWhenTheRegistrationIsUnreadable() {
        let root = "/Users/rasmus/Projects/mine/sild/helm"
        let stores = [store(key: "helm-3ec376fc", path: nil)]
        XCTAssertEqual(WorkspaceStore.store(forRoot: root, in: stores)?.key, "helm-3ec376fc")
    }

    func testStoreIsNilWhenNothingHasWrittenArtifactsYet() {
        XCTAssertNil(
            WorkspaceStore.store(forRoot: "/x/brand-new", in: [store(key: "k", path: "/x/other")])
        )
    }

    // MARK: - Helpers

    private func store(key: String, path: String?) -> ArtifactStore {
        ArtifactStore(
            key: key, name: key, projectPath: path, root: URL(fileURLWithPath: "/dev/null"))
    }

    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "helm-workspace-tests-\(UUID().uuidString)"))
    }

    private func makeRepo(named name: String) throws -> URL {
        let dir = tempRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main", dir.path])
        // A worktree needs a commit to branch from.
        try runGit([
            "-C", dir.path, "-c", "user.email=t@example.com", "-c", "user.name=t",
            "commit", "-q", "--allow-empty", "-m", "init",
        ])
        return dir
    }

    private func addWorktree(named name: String, to repo: URL) throws -> URL {
        let dir = tempRoot.appendingPathComponent("\(repo.lastPathComponent)-wt-\(name)")
        try runGit(["-C", repo.path, "worktree", "add", "-q", "-b", name, dir.path])
        return dir
    }

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> String {
        try run("/usr/bin/env", ["git"] + arguments)
    }

    /// Fed through stdin, not argv: Foundation converts process arguments to the
    /// file-system representation (NFD on macOS), which would silently re-encode a
    /// non-ASCII path and make the comparison meaningless.
    private func gitHashObject(_ content: String) throws -> String {
        try run("/usr/bin/env", ["git", "hash-object", "--stdin"], stdin: content)
    }

    /// prp's canonical store-key resolver, verbatim from the PRP skills' shell
    /// preamble. The reference implementation `WorkspaceStore` is a port of.
    private func canonicalStoreKey(runIn directory: String) throws -> String {
        let script = """
            cd "$1" || exit 1
            _gd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
            case "$_gd" in */.git) _root="${_gd%/.git}" ;; "") _root="$PWD" ;; *) _root="$_gd" ;; esac
            _root="$(cd "$_root" && pwd -P)"
            _name="$(basename "$_root" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' \
                | sed 's/^-*//;s/-*$//')"
            printf '%s-%s' "${_name:-project}" \
                "$(printf %s "$_root" | git hash-object --stdin | cut -c1-8)"
            """
        return try run("/bin/sh", ["-c", script, "sh", directory])
    }

    private func run(
        _ executable: String, _ arguments: [String], stdin: String? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let input = Pipe()
        if let stdin {
            process.standardInput = input
        }
        // Isolate from the developer's git config (templates, default branch, hooks).
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            input.fileHandleForWriting.closeFile()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WorkspaceTests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments) failed"]
            )
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
