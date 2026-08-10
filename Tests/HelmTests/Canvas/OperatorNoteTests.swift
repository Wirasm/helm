import XCTest

@testable import Helm

/// Where a note the operator starts lands, and what it is called (#289).
///
/// **The recogniser half of this suite moved to `EditableFileTests`, and the rule it pinned is
/// inverted there.** It asserted that an agent's plan is not a note and therefore not editable —
/// #307's scope line, drawn because the conflict question had no answer. That answer is built now,
/// so `OperatorNote` no longer decides what may be written into and there is nothing here left to
/// ask it. What stayed is the half that was always its own: creating one.
///
/// Every test here runs against a **temporary artifact root**, never `~/.prp` — the whole reason
/// `create` takes one. Nothing in this file can touch the operator's own store.
final class OperatorNoteTests: XCTestCase {
    /// Stands in for `~/.prp`.
    private var root: URL!
    /// Stands in for a repository the operator has open as a workspace.
    private var workspace: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-operator-note-\(UUID().uuidString)")
        root = base.appendingPathComponent("prp")
        workspace = base.appendingPathComponent("a-project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: - Which store

    func testAnExistingRegistrationWinsOverADerivedKey() throws {
        let registered = try store(key: "custom-name", registering: workspace.path)

        XCTAssertEqual(
            OperatorNote.key(forRepositoryRoot: workspace.path, in: [registered]), "custom-name",
            "matching beats deriving — a store records its own root, so the first pass is a "
                + "string compare with no algorithm to drift from prp's")
    }

    /// A project no agent has written an artifact for yet still has one right answer, and it is
    /// prp's own: the note lands where prp will put its first plan.
    func testWithNoStoreYetTheKeyIsTheOnePrpItselfWouldDerive() {
        XCTAssertEqual(
            OperatorNote.key(forRepositoryRoot: "/x/helm", in: []),
            WorkspaceStore.derivedKey(forRoot: "/x/helm"))
    }

    // MARK: - What it is called

    func testTheFilenameIsDatedAndSaysWhatItIs() {
        XCTAssertEqual(
            OperatorNote.filename(on: day("2026-08-07"), avoiding: []), "2026-08-07-note.md")
    }

    func testASecondNoteOnTheSameDayTakesTheNextSuffix() {
        XCTAssertEqual(
            OperatorNote.filename(on: day("2026-08-07"), avoiding: ["2026-08-07-note.md"]),
            "2026-08-07-note-2.md")
        XCTAssertEqual(
            OperatorNote.filename(
                on: day("2026-08-07"),
                avoiding: ["2026-08-07-note.md", "2026-08-07-note-2.md"]),
            "2026-08-07-note-3.md")
    }

    // MARK: - Creating one

    func testANoteLandsInTheWorkspacesOwnStoreAndIsEmpty() throws {
        _ = try store(key: "a-project-abcd1234", registering: resolved(workspace.path))

        let note = try OperatorNote.create(
            inWorkspaceAt: workspace.path, under: root, on: day("2026-08-07"))

        XCTAssertEqual(
            note.url.path,
            root.appendingPathComponent("a-project-abcd1234/notes/2026-08-07-note.md").path)
        XCTAssertEqual(
            try String(contentsOf: note.url, encoding: .utf8), "",
            "empty rather than templated — the first line is the one the operator already has")
    }

    /// **A note that opens and then refuses to take a character is the one failure ⌘⇧N cannot
    /// survive**, because it goes straight into the writing face. So the file `create` makes has
    /// to be one `EditableFile` recognises — which is what `create` checks for itself, and what
    /// this pins from the outside.
    func testTheNoteHelmMakesIsOneItWillLetHimWriteIn() throws {
        let note = try OperatorNote.create(
            inWorkspaceAt: workspace.path, under: root, on: day("2026-08-07"))

        XCTAssertNotNil(EditableFile(note.url))
    }

    /// **Without a registration the note would be invisible.** `ArtifactStoreDiscovery` lists a
    /// directory as a store only when it holds a `project.json`, so a note in an unregistered key
    /// could not be found again through ⌘O — the one surface that would otherwise show it.
    func testAProjectWithNoStoreYetIsRegisteredSoTheBrowserCanFindTheNote() throws {
        let note = try OperatorNote.create(
            inWorkspaceAt: workspace.path, under: root, on: day("2026-08-07"))

        let stores = ArtifactStoreDiscovery.discoverStores(under: root)
        let store = try XCTUnwrap(stores.first, "helm registered nothing, so ⌘O lists nothing")
        XCTAssertEqual(
            store.projectPath, resolved(workspace.path),
            "prp's own two fields, from the resolved repository root")
        XCTAssertEqual(store.name, WorkspaceStore.slug(forRoot: resolved(workspace.path)))
        // By the store-relative path the browser actually renders, not by URL: `discoverStores`
        // hands back the directory as it walked it, so a `/var` vs `/private/var` comparison
        // would fail for a reason that has nothing to do with this feature.
        XCTAssertTrue(
            ArtifactStoreDiscovery.artifactFiles(in: store.root)
                .contains { $0.relativePath == "notes/\(note.url.lastPathComponent)" },
            "the note has to appear in the browser's own listing, not merely on disk")
    }

    /// prp's design note says `project.json` *"has exactly one writer (whoever first touches the
    /// store)"*. helm touching it first is what the test above is about; this is the other half —
    /// helm arriving second changes nothing.
    func testAnExistingRegistrationIsNeverRewritten() throws {
        let key = WorkspaceStore.derivedKey(forRoot: resolved(workspace.path))
        let store = root.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let registration = store.appendingPathComponent("project.json")
        let original = #"{"path": "/somewhere/else", "name": "as prp wrote it"}"#
        try original.write(to: registration, atomically: true, encoding: .utf8)

        _ = try OperatorNote.create(inWorkspaceAt: workspace.path, under: root)

        XCTAssertEqual(
            try String(contentsOf: registration, encoding: .utf8), original,
            "prp owns this file wherever it wrote it; helm only fills a gap")
    }

    func testTwoNotesInOneDayAreTwoFiles() throws {
        let first = try OperatorNote.create(
            inWorkspaceAt: workspace.path, under: root, on: day("2026-08-07"))
        let second = try OperatorNote.create(
            inWorkspaceAt: workspace.path, under: root, on: day("2026-08-07"))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.url.lastPathComponent, "2026-08-07-note-2.md")
    }

    /// A ⌘⇧N that silently does nothing is the shape of failure this repository has paid for
    /// repeatedly — so an artifact root helm cannot write into is a thrown failure carrying the
    /// sentence the operator reads.
    func testAnArtifactRootHelmCannotWriteIntoIsAFailureWithASentence() throws {
        let unwritable = URL(fileURLWithPath: "/System/helm-should-not-write-here")

        XCTAssertThrowsError(
            try OperatorNote.create(inWorkspaceAt: workspace.path, under: unwritable)
        ) { error in
            guard case OperatorNote.Failure.couldNotWrite(let reason) = error else {
                return XCTFail("expected a couldNotWrite failure, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty, "a refusal with no reason is the silence, not the fix")
        }
    }

    // MARK: - Helpers

    private func store(key: String, registering path: String) throws -> ArtifactStore {
        let directory = root.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"path": "\#(path)", "name": "\#(key)"}"#
            .write(
                to: directory.appendingPathComponent("project.json"), atomically: true,
                encoding: .utf8)
        return ArtifactStore(key: key, name: key, projectPath: path, root: directory)
    }

    /// `pwd -P` semantics, which is what `WorkspaceStore.repositoryRoot` returns for a folder
    /// that is not a repository — on macOS `/var/folders/…` resolves to `/private/var/folders/…`,
    /// and comparing against the unresolved path would fail for a reason that has nothing to do
    /// with this feature.
    private func resolved(_ path: String) -> String {
        WorkspaceStore.repositoryRoot(for: path)
    }

    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // Noon, so the date the filename carries is that day in any timezone the machine runs in.
        formatter.timeZone = TimeZone.current
        return formatter.date(from: text)!.addingTimeInterval(12 * 3600)
    }
}
