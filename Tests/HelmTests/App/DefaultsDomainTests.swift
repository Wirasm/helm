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

    // MARK: - HELM_DEFAULTS_SUITE (#86)

    /// The default, and the property #45 bought: no variable, no change, one domain.
    func testNoVariableIsTodaysBehaviourExactly() {
        XCTAssertEqual(DefaultsDomain.override(in: [:]), .none)
    }

    /// A shell that exports the variable empty — `HELM_DEFAULTS_SUITE=` — meant no override,
    /// and `UserDefaults(suiteName: "")` hands back a usable object writing to a nameless
    /// domain rather than refusing, so nothing below this line would catch it.
    func testABlankVariableIsTheSameAsNoVariable() {
        for blank in ["", " ", "\t", "\n", "  \n "] {
            XCTAssertEqual(
                DefaultsDomain.override(in: [DefaultsDomain.suiteVariable: blank]), .none,
                "\(blank.debugDescription) is not a suite name")
        }
    }

    /// Asking for the canonical domain is asking for the default. It cannot go through
    /// `UserDefaults(suiteName:)` — that returns nil for the running process's own bundle
    /// identifier — so it has to be answered before the suite is ever opened.
    func testAskingForTheCanonicalDomainIsTheDefaultRatherThanAFailure() {
        XCTAssertEqual(
            DefaultsDomain.override(in: [DefaultsDomain.suiteVariable: DefaultsDomain.canonical]),
            .none)
    }

    /// The ordinary case, and the one Task 27 runs on.
    func testANameBecomesASuite() {
        XCTAssertEqual(
            DefaultsDomain.override(in: [DefaultsDomain.suiteVariable: "helm-task27"]),
            .suite("helm-task27"),
            "a plain name is what the variable is for")
        XCTAssertEqual(
            DefaultsDomain.override(in: [DefaultsDomain.suiteVariable: "  helm-task27  "]),
            .suite("helm-task27"),
            "and it survives the whitespace a copied-and-pasted export brings with it")
    }

    /// The legacy domain is drained by the migration and left holding a forwarding note. A
    /// suite pointed at it would be emptied by the operator's own next launch, which is a
    /// worse outcome than no isolation because it looks like isolation until it is gone.
    func testTheLegacyDomainIsRefusedRatherThanHandedOut() {
        guard
            case .refused(let why) = DefaultsDomain.override(
                in: [DefaultsDomain.suiteVariable: DefaultsDomain.legacy])
        else { return XCTFail("the drained domain must not be offered as a suite") }
        XCTAssertTrue(why.contains(DefaultsDomain.legacy), "the refusal must name what was asked")
    }

    /// A path is the shape a name takes when someone reaches for a file. `suiteName:` would
    /// accept it and write a plist somewhere nobody will look for it.
    func testAPathIsRefused() {
        guard
            case .refused = DefaultsDomain.override(
                in: [DefaultsDomain.suiteVariable: "/tmp/helm-test"])
        else { return XCTFail("a suite name is a domain, not a path") }
    }

    /// `NSGlobalDomain` is every application's preferences at once. `UserDefaults(suiteName:)`
    /// refuses it itself, and this pins that helm passes the refusal on rather than trapping.
    func testTheGlobalDomainIsRefused() {
        guard
            case .refused = DefaultsDomain.override(
                in: [DefaultsDomain.suiteVariable: "NSGlobalDomain"])
        else { return XCTFail("writing every app's defaults is not an isolated instance") }
    }

    /// **The acceptance criterion this file exists to hold.** The move empties the legacy
    /// domain and marks the destination so it never runs again. A test instance that ran it
    /// would take state the operator's own build has not migrated yet and then stop it from
    /// ever trying.
    func testTheLegacyMigrationDoesNotFireAgainstASuite() {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("suite")
        seed(["helmWorkspaces": #"["/live"]"#], into: old)

        XCTAssertFalse(
            DefaultsDomain.migrateLegacyDomainAtLaunch(
                override: .suite(new), from: old, to: new, using: defaults),
            "an isolated instance has nothing to inherit")

        XCTAssertEqual(
            contents(of: old)["helmWorkspaces"] as? String, #"["/live"]"#,
            "and must leave the legacy domain full for the build that does")
        XCTAssertTrue(contents(of: new).isEmpty, "nothing arrives, not even the marker")
    }

    /// The same entry point with no override still does the whole job — otherwise the guard
    /// above would be indistinguishable from having disabled the migration outright.
    func testTheLegacyMigrationStillFiresWithoutOne() {
        let old = isolatedDefaultsDomain("legacy")
        let new = isolatedDefaultsDomain("canonical")
        seed(["helmWorkspaces": #"["/live"]"#], into: old)

        XCTAssertTrue(
            DefaultsDomain.migrateLegacyDomainAtLaunch(
                override: .none, from: old, to: new, using: defaults))
        XCTAssertEqual(try workspaces(in: new), ["/live"])
    }

    /// The variable is only isolation if *every* default helm owns goes through
    /// `DefaultsDomain.store`. One `UserDefaults.standard` left behind is one key still
    /// landing in the operator's domain, and it would be invisible — the app runs, the badge
    /// shows, and only that key lies.
    ///
    /// A source scan rather than a behavioural test because there is no seam to assert
    /// against: `UserDefaults.standard` resolves at the call site. `IsolatedDefaultsTests`
    /// makes the same argument for the test target's own suites.
    func testNoSourceFileReachesForStandardDefaultsOutsideTheResolver() throws {
        // The resolver is where `.standard` legitimately survives: it is the handle the
        // migration reads and replaces *other* domains by name through.
        let exempt = "DefaultsDomain.swift"

        var offenders: [String] = []
        for file in try swiftSources() where file.lastPathComponent != exempt {
            let source = try code(in: file)
            if source.contains("UserDefaults.standard")
                || source.contains("UserDefaults(suiteName:")
            {
                offenders.append(file.lastPathComponent)
            }
        }

        XCTAssertEqual(
            offenders, [],
            """
            these reach UserDefaults directly and so escape HELM_DEFAULTS_SUITE — \
            persist through `DefaultsDomain.store` instead (#86)
            """)
    }

    /// The `@AppStorage` half of the same rule, and the easier one to get wrong: the wrapper
    /// binds to `UserDefaults.standard` when no `store:` is given, and reads as if it had
    /// asked for nothing at all.
    ///
    /// `.defaultAppStorage` on the root was considered and rejected. Two mechanisms for one
    /// rule is how the next `@AppStorage` — written in a view three slices away, correct
    /// under one of them and not the other — leaks without anyone noticing.
    func testNoAppStorageOmitsItsStore() throws {
        var offenders: [String] = []
        for file in try swiftSources() {
            for call in balancedCalls(of: "@AppStorage(", in: try code(in: file))
            where !call.contains("store:") {
                offenders.append("\(file.lastPathComponent): \(call)")
            }
        }

        XCTAssertEqual(
            offenders, [],
            "an @AppStorage without `store:` writes UserDefaults.standard whatever "
                + "HELM_DEFAULTS_SUITE says (#86)")
    }

    /// A file with its `//` and `///` lines dropped.
    ///
    /// Both scans above are about what the code *does*, and prose that names the thing it is
    /// replacing is the ordinary way to explain a change. `HelmApp.init` says "until #45 the
    /// two launch paths resolved `UserDefaults.standard` to two different domains", which is
    /// the history that makes the line below make sense — a guard that made that unsayable
    /// would be trading a comment for a grep.
    ///
    /// A trailing comment on a line of code leaves the code, so nothing hides behind one.
    private func code(in file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Every `.swift` under `Sources/`, so a new slice is scanned the day it is added rather
    /// than the day someone remembers to list it.
    private func swiftSources() throws -> [URL] {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        let walk = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Each `opening…)` call in `source`, brace-counted to its own closing paren.
    ///
    /// A line-wise scan would pass a wrapped `@AppStorage(\n  key,\n  store: …)` as a
    /// violation and a one-liner as clean, which is the wrong way round for a guard.
    private func balancedCalls(of opening: String, in source: String) -> [String] {
        var calls: [String] = []
        var rest = Substring(source)
        while let start = rest.range(of: opening) {
            var depth = 0
            var index = start.upperBound
            // `start` ends just past the "(" the marker carries, so the counter opens at 1.
            depth = 1
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "(" { depth += 1 }
                if rest[index] == ")" { depth -= 1 }
                index = rest.index(after: index)
            }
            calls.append(String(rest[start.lowerBound..<index]))
            rest = rest[index...]
        }
        return calls
    }

    /// The drift guard, and the reason it is worth scanning build files from a unit test: the
    /// identity is stated in three files that nothing else compares. If they disagree the two
    /// launch paths quietly go back to two domains, every test here still passes, and the only
    /// symptom is the one that took hours to diagnose the first time.
    func testEveryBuildPathNamesTheOneDomain() throws {
        let root = repositoryRoot

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

    /// The override's own drift guard. An affordance nobody knows about gets reinvented, and
    /// that reinvention — a hand-rolled bundle identifier per PR — is what #86 was filed to
    /// end. `AGENTS.md` is the file an agent reads before touching this repo, so the variable
    /// has to be named in it by the same string the source resolves.
    func testTheOverrideIsDocumentedWhereAgentsWillReadIt() throws {
        let agents = try String(
            contentsOf: repositoryRoot.appendingPathComponent("AGENTS.md"), encoding: .utf8)

        XCTAssertTrue(
            agents.contains(DefaultsDomain.suiteVariable),
            "AGENTS.md must name \(DefaultsDomain.suiteVariable) — an isolated instance an "
                + "agent cannot find out about is one they will hand-roll instead")
    }

    /// Four levels up from `Tests/HelmTests/App/`, and the reason a unit test knows where the
    /// repository is at all: the identity and the affordance are both stated in files no
    /// compiler reads.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }
}
