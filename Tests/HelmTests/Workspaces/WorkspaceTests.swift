import Foundation
import XCTest

@testable import Helm

/// The workspace value type and the open-workspace list's persistence.
/// Store resolution moved to `WorkspaceStoreTests` with the type itself.
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
        let defaults = try isolatedDefaults("workspace")
        let workspaces = [Workspace(path: "/a/b"), Workspace(path: "/a/b/.worktrees/fix")]

        WorkspacePersistence.save(workspaces, to: defaults)
        XCTAssertEqual(WorkspacePersistence.load(from: defaults), workspaces)
        // Stored as a plain string under the @AppStorage-compatible key.
        XCTAssertNotNil(defaults.string(forKey: "helmWorkspaces"))
    }

    func testCorruptOrMissingBlobLoadsAsEmptyList() throws {
        let defaults = try isolatedDefaults("workspace")
        XCTAssertEqual(WorkspacePersistence.load(from: defaults), [])

        defaults.set("{not json", forKey: WorkspacePersistence.listKey)
        XCTAssertEqual(WorkspacePersistence.load(from: defaults), [])
    }

    func testSelectionPersistsOnlyWhileItIsStillOpen() throws {
        let defaults = try isolatedDefaults("workspace")
        let open = [Workspace(path: "/a/b")]

        WorkspacePersistence.saveSelection(open[0], to: defaults)
        XCTAssertEqual(WorkspacePersistence.loadSelection(from: defaults, in: open), open[0])

        // A remembered selection that is no longer in the list falls back to All.
        XCTAssertNil(WorkspacePersistence.loadSelection(from: defaults, in: []))

        WorkspacePersistence.saveSelection(nil, to: defaults)
        XCTAssertNil(WorkspacePersistence.loadSelection(from: defaults, in: open))
    }

}
