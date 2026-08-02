import Foundation
import XCTest

@testable import Helm

/// One domain for both launch paths (#45), and the move that gets the old one's state there.
///
/// The migration runs at most once per machine and empties a domain when it does, so it gets
/// no second chance and cannot be tried out in production. Everything below is on throwaway
/// domains from `isolatedDefaultsDomain(_:)`.
final class DefaultsDomainTests: XCTestCase {
    private let defaults = UserDefaults.standard

    private func seed(_ contents: [String: Any], into domain: String) {
        defaults.setPersistentDomain(contents, forName: domain)
        defaults.synchronize()
    }

    private func contents(of domain: String) -> [String: Any] {
        defaults.persistentDomain(forName: domain) ?? [:]
    }

    /// The persisted workspace list as plain paths.
    ///
    /// Read straight out of the blob rather than through `WorkspacePersistence`, and the
    /// contexts below the same way: what the migration owes is a readable collection with
    /// every member in it, and a test that went through the owning slice's loader would pass
    /// on a blob that loader happened to be lenient about.
    ///
    /// Key names are spelled out for the same reason — the migration reads them off the slices
    /// that own them so it cannot drift, which means only a literal here notices a rename, and
    /// a rename orphans every existing user's list.
    private func workspaces(in domain: String) throws -> [String] {
        let raw = try XCTUnwrap(contents(of: domain)["helmWorkspaces"] as? String)
        return try JSONDecoder().decode([String].self, from: Data(raw.utf8))
    }

    private func workspaceContexts(in domain: String) throws -> [String: Any] {
        let raw = try XCTUnwrap(contents(of: domain)["helmWorkspaceContexts"] as? String)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    /// The whole point of choosing a winner: the two domains disagree about live things —
    /// which workspace is selected, which store the artifact browser opens on — and the domain
    /// `swift run helm` has been writing is the one the operator is actually looking at.
    ///
    /// Both keys here are **scalars**, and that is the point. This test used to make its case
    /// on `helmWorkspaces`, which is a set: collisions there are unioned rather than won, and
    /// the tests below own that rule.
    func testTheOldDomainWinsCollisionsAndKeysOnlyTheNewOneHasSurvive() {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed(
            ["helmSelectedWorkspace": "/live", "artifactBrowserStore": "helm-3ec376fc"],
            into: old)
        seed(
            [
                "helmSelectedWorkspace": "/stale", "artifactBrowserStore": "kild-bcc2213a",
                "helmTerminalFontSize": 15.0,
            ], into: new)

        XCTAssertTrue(DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults))

        let merged = contents(of: new)
        XCTAssertEqual(
            merged["helmSelectedWorkspace"] as? String, "/live",
            "the workspace the operator was last in must still be the selected one")
        XCTAssertEqual(
            merged["artifactBrowserStore"] as? String, "helm-3ec376fc",
            "⌘O must keep opening on the store the operator last picked, not the other build's")
        XCTAssertEqual(
            merged["helmTerminalFontSize"] as? Double, 15.0,
            "a key only the new domain has is not a collision and must not be dropped")
    }

    /// #60: the two domains hold different *subsets of one set*, so there is no winner to
    /// pick — picking one deleted `sild` and `kild` from the operator's bar on the first
    /// launch after #45 merged.
    ///
    /// These fixtures are **disjoint**, which is exactly what the older ones were not: theirs
    /// overlapped, so replacing the list and unioning it produced the same answer and every
    /// test passed over the bug.
    func testDisjointWorkspaceListsAreUnionedRatherThanReplaced() throws {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed(["helmWorkspaces": #"["/live"]"#], into: old)
        seed(["helmWorkspaces": #"["/older","/oldest"]"#], into: new)

        XCTAssertTrue(DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults))

        XCTAssertEqual(
            try workspaces(in: new), ["/live", "/older", "/oldest"],
            "every folder either domain had open must survive, the live bar's order first")
    }

    /// One folder, two spellings, one row. De-duplication is on the normalised path because
    /// that is helm's identity for a workspace everywhere else; on the raw string it would
    /// hand the operator two sidebar rows for one folder.
    func testAFolderBothDomainsKnowSurvivesOnceUnderItsNormalisedPath() throws {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed(["helmWorkspaces": #"["/shared","/live"]"#], into: old)
        seed(["helmWorkspaces": #"["/shared/","/older"]"#], into: new)

        XCTAssertTrue(DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults))

        XCTAssertEqual(
            try workspaces(in: new), ["/shared", "/live", "/older"],
            "a trailing slash is display noise, not a second workspace")
    }

    /// The same bug one shape down — the one #60 calls latent, because this dictionary
    /// survived #45 only by the accident of the losing side being a subset. A member dropped
    /// here is a whole workspace's tab row, not a folder that reopens with one ⌘⇧O.
    func testWorkspaceContextsAreMergedPerPathWithTheLiveDomainWinning() throws {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed(["helmWorkspaceContexts": #"{"/shared":{"branch":"live"}}"#], into: old)
        seed(
            [
                "helmWorkspaceContexts":
                    #"{"/shared":{"branch":"stale"},"/older":{"branch":"older"}}"#
            ], into: new)

        XCTAssertTrue(DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults))

        let merged = try workspaceContexts(in: new)
        XCTAssertEqual(
            Set(merged.keys), ["/shared", "/older"],
            "a path only the canonical domain had a context for is still a workspace")
        XCTAssertEqual(
            (merged["/shared"] as? [String: Any])?["branch"] as? String, "live",
            "where both hold one, the live domain's context wins — as the scalars do")
    }

    /// The commonest shape of all, and the one with the most to lose: a machine that only ever
    /// ran `swift run helm` has a list on one side and nothing on the other. There is no union
    /// to compute, so this guards the guard — reading "the other side does not decode" as
    /// "there is nothing to keep" would migrate that machine to an empty bar.
    func testAListOnlyTheLegacyDomainHasArrivesWhole() throws {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed(["helmWorkspaces": #"["/live","/also-live"]"#], into: old)

        XCTAssertTrue(DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults))

        XCTAssertEqual(
            try workspaces(in: new), ["/live", "/also-live"],
            "nothing on the other side is not a reason to arrive with less")
    }

    /// The move gets one attempt per machine, so a blob it cannot read must not be allowed to
    /// overwrite one it can. An unreadable list has no members to preserve — the app reads it
    /// as an empty bar too — so standing the readable side up whole loses nothing.
    func testAnUnreadableLegacyListDoesNotOverwriteAReadableOne() throws {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed(["helmWorkspaces": "not json at all"], into: old)
        seed(["helmWorkspaces": #"["/older"]"#], into: new)

        XCTAssertTrue(DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults))

        XCTAssertEqual(
            try workspaces(in: new), ["/older"],
            "last-writer-wins here would trade a readable bar for an empty one")
    }

    /// Nothing about the copy is visible from `defaults read`; only this is. Leaving a full,
    /// plausible copy behind is precisely what cost the hours in #45.
    func testTheOldDomainIsDrainedAndLeftPointingAtTheNewOne() {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed(["helmWorkspaces": "[live]", "helmSelectedWorkspace": "/live"], into: old)

        DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults)

        XCTAssertEqual(
            contents(of: old) as? [String: String], [DefaultsDomain.movedToKey: new],
            "a drained domain must say where its state went and hold nothing else")
    }

    /// An older build run once more refills the old domain. Migrating a second time would let
    /// it overwrite the state that replaced it, which is a worse failure than the original.
    func testTheMoveHappensOnceEvenIfTheOldDomainFillsUpAgain() {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed(["helmWorkspaces": "[live]"], into: old)
        XCTAssertTrue(DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults))
        XCTAssertEqual(contents(of: new)[DefaultsDomain.migratedFromKey] as? String, old)

        seed(["helmWorkspaces": "[from an older build]"], into: old)

        XCTAssertFalse(
            DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults),
            "the marker in the new domain is what makes this idempotent")
        XCTAssertEqual(
            contents(of: new)["helmWorkspaces"] as? String, "[live]",
            "a second move would let a stale domain overwrite what replaced it")
    }

    /// A machine that has only ever run `make app` has no old domain. It must not be given a
    /// marker key it has no use for, and must not be handed a forwarding note to nowhere.
    func testAFreshInstallIsLeftCompletelyAlone() {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed(["helmWorkspaces": "[only ever the app]"], into: new)

        XCTAssertFalse(DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults))

        XCTAssertNil(contents(of: new)[DefaultsDomain.migratedFromKey], "nothing moved")
        XCTAssertEqual(contents(of: new)["helmWorkspaces"] as? String, "[only ever the app]")
        XCTAssertTrue(contents(of: old).isEmpty, "and no domain conjured to forward from")
    }

    /// Belt and braces on the guard above: a domain holding only its own forwarding note has
    /// nothing to give, and must not be read as if it did.
    func testAForwardingNoteIsNotStateAndDoesNotTravel() {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed([DefaultsDomain.movedToKey: "com.somewhere.else"], into: old)

        XCTAssertFalse(DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults))
        XCTAssertTrue(contents(of: new).isEmpty)
    }

    /// The drift guard, and the reason it is worth scanning build files from a unit test: the
    /// identity is stated in three files that nothing else compares. If they disagree the two
    /// launch paths quietly go back to two domains, every test here still passes, and the only
    /// symptom is the one that took hours to diagnose the first time.
    func testEveryBuildPathNamesTheOneDomain() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root

        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: root.appendingPathComponent("SPMInfo.plist")),
            "SPMInfo.plist is the only thing giving `swift run helm` an identifier at all")
        XCTAssertEqual(
            plist["CFBundleIdentifier"] as? String, DefaultsDomain.canonical,
            "the SPM binary must land in the same domain the source says it does")

        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(
            manifest.contains("__info_plist") && manifest.contains("SPMInfo.plist"),
            "a plist nothing links in is a file, not an identity — Package.swift must embed it")

        let spec = try String(
            contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(
            spec.contains("PRODUCT_BUNDLE_IDENTIFIER: \(DefaultsDomain.canonical)"),
            "and Helm.app must be the same app as the one the SPM path now claims to be")
    }
}
