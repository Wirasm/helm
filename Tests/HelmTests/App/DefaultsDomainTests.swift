import Foundation
import HelmWire
import XCTest

@testable import Helm

/// One domain for both launch paths (#45), and the opt-in suite that moves it (#86).
///
/// Suites are exercised on throwaway domains from `isolatedDefaultsDomain(_:)`.
final class DefaultsDomainTests: XCTestCase {
    private func contents(of domain: String) -> [String: Any] {
        UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
    }

    // MARK: - HELM_DEFAULTS_SUITE (#86)

    /// The default, and the property #45 bought: no variable, no change, one domain.
    func testNoVariableIsTodaysBehaviourExactly() {
        XCTAssertEqual(DefaultsDomain.override(in: [:]), .none)
    }

    /// A shell that exports the variable empty — `HELM_DEFAULTS_SUITE=` — meant no override.
    /// The exactly-empty string is the only blank that is read that way.
    func testAnEmptyVariableIsTheSameAsNoVariable() {
        XCTAssertEqual(DefaultsDomain.override(in: [DefaultsDomain.suiteVariable: ""]), .none)
    }

    /// **Whitespace is a broken value, not a choice**, and this is the distinction that keeps
    /// `override(in:)` from having one silent path. `HELM_DEFAULTS_SUITE="$SUITE "` with
    /// `$SUITE` empty upstream used to resolve to `com.wirasm.helm` with no badge, no title
    /// change and nothing on stderr — an agent believing it was contained, writing live state.
    /// That is #86 reached through the mechanism built to prevent it.
    func testAVariableThatTrimsAwayIsRefusedRatherThanReadAsUnset() {
        for blank in [" ", "\t", "\n", "  \n "] {
            guard
                case .refused = DefaultsDomain.override(
                    in: [DefaultsDomain.suiteVariable: blank])
            else {
                return XCTFail(
                    "\(blank.debugDescription) must be refused, not silently read as unset")
            }
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

    /// The legacy domain is what `swift run helm` wrote before #45, and on a machine that ran
    /// a build from then it still holds that state or the forwarding note the one-time move
    /// left. A suite pointed at it is not isolated from anything.
    func testTheLegacyDomainIsRefusedRatherThanHandedOut() {
        guard
            case .refused(let why) = DefaultsDomain.override(
                in: [DefaultsDomain.suiteVariable: DefaultsSuite.legacy])
        else { return XCTFail("the drained domain must not be offered as a suite") }
        XCTAssertTrue(why.contains(DefaultsSuite.legacy), "the refusal must name what was asked")
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

    /// The decision is only half of it: `override(in:)` can be right and the store it turns
    /// into still be wrong. `.none` in particular must land on `UserDefaults.standard` rather
    /// than on a suite *named* `com.wirasm.helm`, which is not the same domain — the API
    /// refuses that name for this process precisely because it is the app's own.
    func testTheDefaultResolvesToTheCanonicalDomainAndTheStandardStore() {
        let resolved = DefaultsDomain.resolve(.none)

        XCTAssertEqual(resolved.name, DefaultsDomain.canonical)
        XCTAssertTrue(
            resolved.defaults === UserDefaults.standard,
            "unset must be today's behaviour to the object, not merely to the name")
    }

    /// And a suite must resolve to a store that writes *there*, which is the whole promise.
    func testASuiteResolvesToAStoreThatWritesOnlyToIt() throws {
        let name = isolatedDefaultsDomain("resolved")

        let resolved = DefaultsDomain.resolve(.suite(name))
        resolved.defaults.set("written", forKey: "helmProbe")
        resolved.defaults.synchronize()

        XCTAssertEqual(resolved.name, name)
        XCTAssertEqual(
            contents(of: name)["helmProbe"] as? String, "written",
            "the store handed back must be the one that domain reads")
        XCTAssertNil(
            UserDefaults.standard.persistentDomain(forName: DefaultsDomain.canonical)?[
                "helmProbe"],
            "and nothing it writes may appear in the operator's domain")
    }

    /// **Polarity**, pinned rather than eyeballed. `AGENTS.md` has `winshot --list` and
    /// `helm-capture --window` telling two helms apart by this title, so backwards is not a
    /// cosmetic bug — it is a safety mechanism pointing at the wrong instance.
    func testOnlyANonCanonicalDomainReadsAsIsolated() {
        XCTAssertFalse(DefaultsDomain.isIsolated(domain: DefaultsDomain.canonical))
        XCTAssertTrue(DefaultsDomain.isIsolated(domain: "helm-task27"))

        XCTAssertEqual(
            DefaultsDomain.windowTitle(for: DefaultsDomain.canonical), "helm",
            "the operator's helm is titled what it has always been titled")
        XCTAssertEqual(
            DefaultsDomain.windowTitle(for: "helm-task27"), "helm — helm-task27",
            "and a test instance names its suite where a tool outside the process can read it")
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
        // The resolver is where `.standard` legitimately survives: it is what `.none`
        // resolves to. `DefaultsSuite.swift`
        // (#221) is exempt for the same reason one door over: `SpoolDirectory.resolve` needs
        // the identical `UserDefaults(suiteName:)` probe `DefaultsDomain.override` makes, to
        // tell a real suite name from one `UserDefaults` will refuse — and `DefaultsDomain`
        // now delegates to it rather than restating the check. Neither file ever touches
        // `.standard`, which is the actual thing this guard is about.
        let exempt: Set<String> = ["DefaultsDomain.swift", "DefaultsSuite.swift"]

        var offenders: [String] = []
        for file in try swiftSources() where !exempt.contains(file.lastPathComponent) {
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
            var index = start.upperBound
            // `start` ends just past the "(" the marker carries, so the counter opens at 1.
            var depth = 1
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

    /// Four levels up from `Tests/HelmTests/App/`, and the reason a unit test knows where the
    /// repository is at all: the identity is stated in files no compiler reads.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }
}
