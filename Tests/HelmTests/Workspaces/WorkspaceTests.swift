import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The workspace value type, and the open-workspace list following benchd's document.
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
        XCTAssertEqual(workspace.id, WorkspacePath("/Users/dev/Projects/sild/helm"))
        XCTAssertEqual(workspace.name, "helm")

        // Two checkouts of one repo are two DISTINCT workspaces — the thing a
        // unique-name registry could not express.
        let worktree = Workspace(path: "/Users/dev/Projects/sild/helm/.worktrees/fix")
        XCTAssertNotEqual(workspace, worktree)
        XCTAssertEqual(worktree.name, "fix")
    }

    func testConstructionNormalisesTrailingSlashesAndTilde() {
        XCTAssertEqual(Workspace(path: "/a/b/").path.value, "/a/b")
        XCTAssertEqual(Workspace(path: "/a/b///").path.value, "/a/b")
        XCTAssertEqual(Workspace(path: "/").path.value, "/")
        XCTAssertEqual(
            Workspace(path: "~/code").path.value,
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

    // MARK: - The list follows benchd's document

    @MainActor
    func testTheListAndTheSelectionAreTheDocuments() {
        let model = WorkspaceModel(readBranch: { _ in nil })
        let bench = ToyBench.bench([ToyBench.terminal()])

        model.follow(
            BenchDocument(
                workspaces: [.init(path: "/a/b/", bench: bench), .init(path: "/c", bench: bench)],
                active: "/c"))

        XCTAssertEqual(model.workspaces, [Workspace(path: "/a/b"), Workspace(path: "/c")])
        XCTAssertEqual(model.selectedWorkspace, Workspace(path: "/c"))

        model.follow(BenchDocument(workspaces: [], active: nil))
        XCTAssertEqual(model.workspaces, [])
        XCTAssertNil(model.selectedWorkspace)
    }
}
