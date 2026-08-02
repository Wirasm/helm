import XCTest

@testable import Helm

/// The browser's selection-then-listing rule, over a fixture artifact root.
///
/// This is the part #50 was actually about. The rule used to live in two private methods
/// on `ArtifactBrowser`, so nothing here could reach it, and a browser that listed nothing
/// on a store holding 26 artifacts shipped without a single test going red. The display
/// symptom was a popover-sizing bug; the defect was that this was unreachable.
final class ArtifactListingTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-artlisting-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    // MARK: Fixture helpers

    /// A store whose `project.json` "path" is `/Users/x/<key>` — the field an open
    /// workspace folder is matched against.
    @discardableResult
    private func makeStore(_ key: String, name: String) throws -> URL {
        let dir = fixtureRoot.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{\"path\": \"/Users/x/\(key)\", \"name\": \"\(name)\"}".write(
            to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8
        )
        return dir
    }

    private func addFile(_ relativePath: String, in store: URL, modified: Date? = nil) throws {
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
    }

    private func load(workspaceRoot: String? = nil, remembered: String = "") -> ArtifactListing {
        .load(root: fixtureRoot, workspaceRoot: workspaceRoot, remembered: remembered)
    }

    // MARK: The listing itself

    /// #50 in one assertion: a selected store with artifacts in it lists them. This is the
    /// state the operator saw empty, and nothing could assert it before.
    func testSelectingAStoreListsItsArtifacts() throws {
        let helm = try makeStore("helm-bbbbbbbb", name: "helm")
        let now = Date()
        try addFile("briefs/issue-50.md", in: helm, modified: now.addingTimeInterval(-60))
        try addFile("issues/completed/issue-44.md", in: helm, modified: now.addingTimeInterval(-30))
        try addFile("plans/canvas.html", in: helm, modified: now.addingTimeInterval(-90))

        let listing = load(workspaceRoot: "/Users/x/helm-bbbbbbbb")

        XCTAssertEqual(listing.selectedKey, "helm-bbbbbbbb")
        XCTAssertEqual(
            listing.files.map(\.relativePath),
            ["issues/completed/issue-44.md", "briefs/issue-50.md", "plans/canvas.html"]
        )
    }

    /// The distinction #20 insists on, between nothing to show and nothing being asked: an
    /// empty store is still *selected*, which is what puts the browser on the
    /// "No artifacts in this project yet." branch rather than the "no stores found" one.
    func testAnEmptyStoreIsStillSelectedAndListsNothing() throws {
        try makeStore("fresh-cccccccc", name: "fresh")

        let listing = load(workspaceRoot: "/Users/x/fresh-cccccccc")

        XCTAssertEqual(listing.selectedKey, "fresh-cccccccc")
        XCTAssertEqual(listing.selectedStore?.key, "fresh-cccccccc")
        XCTAssertTrue(listing.files.isEmpty)
        XCTAssertFalse(listing.stores.isEmpty)
    }

    /// Nothing discovered at all — the other branch, and the one `ArtifactListing.none`
    /// stands for.
    func testNoStoresSelectsNothing() {
        let listing = load(workspaceRoot: "/Users/x/anything")

        XCTAssertEqual(listing, .none)
        XCTAssertEqual(listing.selectedKey, "")
        XCTAssertNil(listing.selectedStore)
    }

    // MARK: The selection rule

    /// The open workspace's store wins over the remembered one — the whole point of
    /// passing the workspace root in.
    func testTheOpenWorkspacesStoreBeatsTheRememberedOne() throws {
        let kild = try makeStore("kild-aaaaaaaa", name: "kild")
        try makeStore("helm-bbbbbbbb", name: "helm")
        try addFile("plans/rooms.md", in: kild)

        let listing = load(workspaceRoot: "/Users/x/kild-aaaaaaaa", remembered: "helm-bbbbbbbb")

        XCTAssertEqual(listing.selectedKey, "kild-aaaaaaaa")
        XCTAssertEqual(listing.files.map(\.relativePath), ["plans/rooms.md"])
    }

    /// No workspace open, or one with no store yet: the remembered key is the fallback,
    /// and it must survive rather than be overwritten by the first store alphabetically.
    func testTheRememberedStoreIsKeptWhenNoWorkspaceMatches() throws {
        try makeStore("alpha-aaaaaaaa", name: "alpha")
        let zulu = try makeStore("zulu-zzzzzzzz", name: "zulu")
        try addFile("research/notes.md", in: zulu)

        XCTAssertEqual(load(remembered: "zulu-zzzzzzzz").selectedKey, "zulu-zzzzzzzz")
        XCTAssertEqual(
            load(workspaceRoot: "/Users/x/brand-new", remembered: "zulu-zzzzzzzz").selectedKey,
            "zulu-zzzzzzzz"
        )
        XCTAssertEqual(
            load(remembered: "zulu-zzzzzzzz").files.map(\.relativePath), ["research/notes.md"]
        )
    }

    /// A remembered store the operator has since deleted must not leave the picker aimed
    /// at a key nothing answers to — that is a browser showing a selection and no files,
    /// which is exactly the state #50 looked like from outside.
    func testARememberedKeyThatNamesNothingFallsBackToTheFirstStore() throws {
        let alpha = try makeStore("alpha-aaaaaaaa", name: "alpha")
        try makeStore("zulu-zzzzzzzz", name: "zulu")
        try addFile("plans/first.md", in: alpha)

        let listing = load(remembered: "deleted-99999999")

        // Stores are sorted by display name, so "alpha" is first.
        XCTAssertEqual(listing.selectedKey, "alpha-aaaaaaaa")
        XCTAssertEqual(listing.files.map(\.relativePath), ["plans/first.md"])
    }

    /// Two workspaces on one repo — a checkout and a worktree — report the same repo root
    /// and so resolve to one store. `WorkspaceStore` owns that rule; this pins that the
    /// listing goes through it rather than matching on the raw folder.
    func testAWorkspaceMatchesItsStoreByTheRegisteredPath() throws {
        try makeStore("helm-bbbbbbbb", name: "helm")

        XCTAssertEqual(load(workspaceRoot: "/Users/x/helm-bbbbbbbb").selectedKey, "helm-bbbbbbbb")
        XCTAssertEqual(load(workspaceRoot: "/Users/x/unrelated").selectedKey, "helm-bbbbbbbb")
    }

    // MARK: Re-selecting from the picker

    /// Picking another store in the picker re-lists that store's files. This is the second
    /// half of what was unreachable: the old `refreshFiles()` read the selection back out
    /// of a property wrapper, so selection and listing could disagree with nothing to say
    /// so. Here they cannot — `files` is only ever the selected store's.
    func testSelectingAnotherStoreRelistsItsFiles() throws {
        let kild = try makeStore("kild-aaaaaaaa", name: "kild")
        let helm = try makeStore("helm-bbbbbbbb", name: "helm")
        try addFile("plans/rooms.md", in: kild)
        try addFile("briefs/issue-50.md", in: helm)

        let listing = load(workspaceRoot: "/Users/x/helm-bbbbbbbb")
        XCTAssertEqual(listing.files.map(\.relativePath), ["briefs/issue-50.md"])

        let switched = listing.selecting("kild-aaaaaaaa")

        XCTAssertEqual(switched.selectedKey, "kild-aaaaaaaa")
        XCTAssertEqual(switched.files.map(\.relativePath), ["plans/rooms.md"])
        // Same stores — switching the picker is not a reason to re-answer what exists.
        XCTAssertEqual(switched.stores, listing.stores)
    }

    /// Selecting a key nothing answers to empties the listing rather than leaving the last
    /// store's files under a different name.
    func testSelectingAnUnknownKeyListsNothing() throws {
        let helm = try makeStore("helm-bbbbbbbb", name: "helm")
        try addFile("briefs/issue-50.md", in: helm)

        let switched = load(workspaceRoot: "/Users/x/helm-bbbbbbbb").selecting("gone-00000000")

        XCTAssertEqual(switched.selectedKey, "gone-00000000")
        XCTAssertNil(switched.selectedStore)
        XCTAssertTrue(switched.files.isEmpty)
    }
}
