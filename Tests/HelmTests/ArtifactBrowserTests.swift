import XCTest

@testable import Helm

/// The artifact browser's pure part — store discovery + file listing over a
/// fixture directory. No views, no popover, no GUI.
final class ArtifactBrowserTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-artbrowser-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    // MARK: Fixture helpers

    @discardableResult
    private func makeStore(_ key: String, name: String?) throws -> URL {
        let dir = fixtureRoot.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var json = "{\"path\": \"/Users/x/\(key)\"}"
        if let name {
            json = "{\"path\": \"/Users/x/\(key)\", \"name\": \"\(name)\"}"
        }
        try json.write(
            to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8
        )
        return dir
    }

    @discardableResult
    private func addFile(
        _ relativePath: String, in store: URL, modified: Date? = nil
    ) throws -> URL {
        let url = store.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "content".write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path
            )
        }
        return url
    }

    // MARK: Store discovery

    func testDiscoveryFindsStoresWithDisplayNamesSortedByName() throws {
        try makeStore("proj-z", name: "Alpha")
        try makeStore("proj-b", name: nil)  // no "name" key → falls back to dir key

        let stores = ArtifactStoreDiscovery.discoverStores(under: fixtureRoot)

        XCTAssertEqual(stores.map(\.name), ["Alpha", "proj-b"])
        XCTAssertEqual(stores.map(\.key), ["proj-z", "proj-b"])
    }

    func testDiscoverySkipsDirectoriesWithoutProjectJSON() throws {
        let dir = fixtureRoot.appendingPathComponent("not-a-store")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try addFile("stray.md", in: dir)

        XCTAssertTrue(ArtifactStoreDiscovery.discoverStores(under: fixtureRoot).isEmpty)
    }

    func testDiscoveryReturnsEmptyForMissingRoot() {
        let missing = fixtureRoot.appendingPathComponent("nope")
        XCTAssertTrue(ArtifactStoreDiscovery.discoverStores(under: missing).isEmpty)
    }

    /// project.json's "path" is read alongside "name" — the field that links an open
    /// workspace folder to its store, parsed and discarded until now.
    func testDiscoveryReadsTheProjectPathAlongsideTheName() throws {
        try makeStore("proj-a", name: "Alpha")
        let bare = fixtureRoot.appendingPathComponent("proj-bare")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try "{}".write(
            to: bare.appendingPathComponent("project.json"), atomically: true, encoding: .utf8
        )

        let stores = ArtifactStoreDiscovery.discoverStores(under: fixtureRoot)

        XCTAssertEqual(stores.first { $0.key == "proj-a" }?.projectPath, "/Users/x/proj-a")
        // A registration without "path" is not a crash and not an empty string.
        XCTAssertNil(stores.first { $0.key == "proj-bare" }?.projectPath)
    }

    // MARK: Workspace → store auto-selection

    /// The browser's default: the open workspace's store, matched on project.json's
    /// "path". Two workspaces on one repo (checkout + worktree) both resolve here,
    /// because both report the SAME repo root.
    func testWorkspaceRootSelectsItsOwnStore() throws {
        try makeStore("kild-aaaaaaaa", name: "kild")
        try makeStore("helm-bbbbbbbb", name: "helm")
        let stores = ArtifactStoreDiscovery.discoverStores(under: fixtureRoot)

        XCTAssertEqual(
            WorkspaceStore.store(forRoot: "/Users/x/helm-bbbbbbbb", in: stores)?.key,
            "helm-bbbbbbbb"
        )
    }

    /// No store for this folder yet → nil, so the picker keeps its last-used value
    /// rather than jumping to an unrelated project.
    func testWorkspaceRootWithoutAStoreFallsBack() throws {
        try makeStore("kild-aaaaaaaa", name: "kild")
        let stores = ArtifactStoreDiscovery.discoverStores(under: fixtureRoot)

        XCTAssertNil(WorkspaceStore.store(forRoot: "/Users/x/brand-new", in: stores))
    }

    // MARK: File listing

    func testFileListingIsFlatWithRelativeNamesSortedByMtime() throws {
        let store = try makeStore("proj", name: "Proj")
        let now = Date()
        try addFile("top.md", in: store, modified: now.addingTimeInterval(-7200))
        try addFile("plans/new.diagrams.md", in: store, modified: now.addingTimeInterval(-60))
        try addFile("reviews/mid.html", in: store, modified: now.addingTimeInterval(-3600))

        let files = ArtifactStoreDiscovery.artifactFiles(in: store)

        // Subdirectory files surface flat, newest first, under relative names.
        XCTAssertEqual(
            files.map(\.relativePath),
            ["plans/new.diagrams.md", "reviews/mid.html", "top.md"]
        )
    }

    func testFileListingSkipsDotfilesProjectJSONAndNonArtifacts() throws {
        let store = try makeStore("proj", name: "Proj")
        try addFile(".hidden.md", in: store)
        try addFile(".secrets/nested.md", in: store)
        try addFile("notes.txt", in: store)
        try addFile("plans/kept.md", in: store)

        let files = ArtifactStoreDiscovery.artifactFiles(in: store)

        // project.json itself must not be listed either.
        XCTAssertEqual(files.map(\.relativePath), ["plans/kept.md"])
    }

    func testFileListingCapsDepthAtTwo() throws {
        let store = try makeStore("proj", name: "Proj")
        try addFile("plans/depth2.md", in: store)
        try addFile("plans/deep/depth3.md", in: store)

        let files = ArtifactStoreDiscovery.artifactFiles(in: store)

        XCTAssertEqual(files.map(\.relativePath), ["plans/depth2.md"])
    }
}
