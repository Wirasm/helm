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

    /// The whole point of choosing a winner: the two domains disagree about live things —
    /// which workspaces are open, which store the artifact browser opens on — and the domain
    /// `swift run helm` has been writing is the one the operator is actually looking at.
    func testTheOldDomainWinsCollisionsAndKeysOnlyTheNewOneHasSurvive() {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed(
            ["helmWorkspaces": "[live]", "artifactBrowserStore": "helm-3ec376fc"],
            into: old)
        seed(
            [
                "helmWorkspaces": "[stale]", "artifactBrowserStore": "kild-bcc2213a",
                "helmTerminalFontSize": 15.0,
            ], into: new)

        XCTAssertTrue(DefaultsDomain.migrateLegacyDomain(from: old, to: new, using: defaults))

        let merged = contents(of: new)
        XCTAssertEqual(merged["helmWorkspaces"] as? String, "[live]", "the live list must win")
        XCTAssertEqual(
            merged["artifactBrowserStore"] as? String, "helm-3ec376fc",
            "⌘O must keep opening on the store the operator last picked, not the other build's")
        XCTAssertEqual(
            merged["helmTerminalFontSize"] as? Double, 15.0,
            "a key only the new domain has is not a collision and must not be dropped")
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
