import XCTest
@testable import Helm

/// The artifact browser's pure parts — store discovery over a fixture
/// directory, the recents codec + pruning, filter matching, and the relative
/// age labels. No views, no popover, no GUI.
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

    func testDiscoveryFindsStoresWithDisplayNames() throws {
        try makeStore("proj-a", name: "Project A")
        try makeStore("proj-b", name: nil) // no "name" key → falls back to dir key

        let stores = ArtifactStoreDiscovery.discoverStores(under: fixtureRoot)

        XCTAssertEqual(stores.count, 2)
        XCTAssertEqual(Set(stores.map(\.name)), ["Project A", "proj-b"])
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

    func testDiscoveryListsArtifactsWithRelativePathsSortedByMtime() throws {
        let store = try makeStore("proj", name: "Proj")
        let now = Date()
        try addFile("plans/old.md", in: store, modified: now.addingTimeInterval(-7200))
        try addFile("plans/new.diagrams.md", in: store, modified: now.addingTimeInterval(-60))
        try addFile("reviews/mid.html", in: store, modified: now.addingTimeInterval(-3600))

        let stores = ArtifactStoreDiscovery.discoverStores(under: fixtureRoot)

        XCTAssertEqual(
            stores.first?.files.map(\.relativePath),
            ["plans/new.diagrams.md", "reviews/mid.html", "plans/old.md"]
        )
    }

    func testDiscoverySkipsDotfilesProjectJSONAndNonArtifacts() throws {
        let store = try makeStore("proj", name: "Proj")
        try addFile(".hidden.md", in: store)
        try addFile(".secrets/nested.md", in: store)
        try addFile("notes.txt", in: store)
        try addFile("plans/kept.md", in: store)

        let stores = ArtifactStoreDiscovery.discoverStores(under: fixtureRoot)

        // project.json itself must not be listed either.
        XCTAssertEqual(stores.first?.files.map(\.relativePath), ["plans/kept.md"])
    }

    func testDiscoveryCapsDepthAtThree() throws {
        let store = try makeStore("proj", name: "Proj")
        try addFile("a/b/depth3.md", in: store)
        try addFile("a/b/c/depth4.md", in: store)

        let stores = ArtifactStoreDiscovery.discoverStores(under: fixtureRoot)

        XCTAssertEqual(stores.first?.files.map(\.relativePath), ["a/b/depth3.md"])
    }

    func testDiscoveryCapsFilesPerStoreAndFlagsMore() throws {
        let store = try makeStore("proj", name: "Proj")
        let now = Date()
        for index in 0..<20 {
            try addFile(
                "plans/file-\(String(format: "%02d", index)).md",
                in: store,
                modified: now.addingTimeInterval(TimeInterval(-index * 60))
            )
        }

        let stores = ArtifactStoreDiscovery.discoverStores(under: fixtureRoot)

        XCTAssertEqual(stores.first?.files.count, ArtifactStoreDiscovery.fileCap)
        XCTAssertEqual(stores.first?.hasMore, true)
        // Newest survives the cap.
        XCTAssertEqual(stores.first?.files.first?.relativePath, "plans/file-00.md")
    }

    func testDiscoveryOrdersStoresByMostRecentActivity() throws {
        let stale = try makeStore("stale", name: "Stale")
        let fresh = try makeStore("fresh", name: "Fresh")
        let now = Date()
        try addFile("plans/old.md", in: stale, modified: now.addingTimeInterval(-86_400))
        try addFile("plans/new.md", in: fresh, modified: now.addingTimeInterval(-60))

        let stores = ArtifactStoreDiscovery.discoverStores(under: fixtureRoot)

        XCTAssertEqual(stores.map(\.name), ["Fresh", "Stale"])
    }

    // MARK: Recents codec

    func testRecentsEncodeDecodeRoundTrip() {
        let paths = ["/a/plan.md", "/b/review.html"]
        XCTAssertEqual(ArtifactRecents.decode(ArtifactRecents.encode(paths)), paths)
    }

    func testRecentsDecodeToleratesGarbage() {
        XCTAssertEqual(ArtifactRecents.decode("not json"), [])
        XCTAssertEqual(ArtifactRecents.decode(""), [])
    }

    func testRecentsAddingMovesToFrontDedupesAndCaps() {
        var paths: [String] = []
        for index in 0..<10 {
            paths = ArtifactRecents.adding("/file-\(index).md", to: paths)
        }
        XCTAssertEqual(paths.count, ArtifactRecents.cap)
        XCTAssertEqual(paths.first, "/file-9.md")

        // Re-adding an existing path moves it to the front without duplicating.
        paths = ArtifactRecents.adding("/file-5.md", to: paths)
        XCTAssertEqual(paths.first, "/file-5.md")
        XCTAssertEqual(paths.filter { $0 == "/file-5.md" }.count, 1)
        XCTAssertEqual(paths.count, ArtifactRecents.cap)
    }

    func testRecentsPruningSkipsMissingFiles() throws {
        let store = try makeStore("proj", name: "Proj")
        let kept = try addFile("plans/kept.md", in: store)
        let missing = store.appendingPathComponent("plans/gone.md")

        XCTAssertEqual(
            ArtifactRecents.pruned([missing.path, kept.path]),
            [kept.path]
        )
        // Injectable existence check for pure-function testing.
        XCTAssertEqual(
            ArtifactRecents.pruned(["/a", "/b", "/c"]) { $0 != "/b" },
            ["/a", "/c"]
        )
    }

    // MARK: Filter matching

    func testFilterEmptyQueryMatchesEverything() {
        XCTAssertTrue(ArtifactFilter.matches(query: "", candidate: "plans/foo.md"))
        XCTAssertTrue(ArtifactFilter.matches(query: "   ", candidate: "plans/foo.md"))
    }

    func testFilterIsCaseInsensitiveSubstring() {
        XCTAssertTrue(ArtifactFilter.matches(query: "FOO", candidate: "plans/foo.diagrams.md"))
        XCTAssertTrue(ArtifactFilter.matches(query: "diagrams", candidate: "plans/foo.diagrams.md"))
        XCTAssertFalse(ArtifactFilter.matches(query: "bar", candidate: "plans/foo.diagrams.md"))
    }

    func testFilterRequiresAllTokens() {
        XCTAssertTrue(ArtifactFilter.matches(query: "plan diagrams", candidate: "plans/foo.diagrams.md"))
        XCTAssertFalse(ArtifactFilter.matches(query: "plan missing", candidate: "plans/foo.diagrams.md"))
    }

    // MARK: Relative age

    func testAgeLabels() {
        let now = Date()
        XCTAssertEqual(ArtifactAge.label(for: now.addingTimeInterval(-5), now: now), "now")
        XCTAssertEqual(ArtifactAge.label(for: now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(ArtifactAge.label(for: now.addingTimeInterval(-7200), now: now), "2h ago")
        XCTAssertEqual(ArtifactAge.label(for: now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
    }
}
