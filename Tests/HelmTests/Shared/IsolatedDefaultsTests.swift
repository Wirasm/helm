import Foundation
import XCTest

/// The cleanup that #46 is about.
///
/// Every assertion here is about the **file**, because that is what `defaults domains` reads.
/// A test that asserted the domain was empty instead would have passed for the whole life of
/// the bug — that is exactly the shape `WorkspaceContextTests` had.
///
/// `synchronize()` is deprecated and used deliberately: cfprefsd persists on its own schedule,
/// and these assertions are about whether a file is on disk *right now*.
final class IsolatedDefaultsTests: XCTestCase {
    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: IsolatedDefaults.url(for: name).path)
    }

    func testRemovingASuiteDeletesItsBackingFile() throws {
        let name = IsolatedDefaults.name(for: "removal")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set("value", forKey: "key")
        defaults.synchronize()
        XCTAssertTrue(exists(name), "precondition: writing to a suite writes a real plist")

        IsolatedDefaults.remove(named: name)

        XCTAssertFalse(
            exists(name),
            "the suite's file must be gone — while it exists, `defaults domains` still lists it")
    }

    /// Pins the assumption the fix rests on: emptying a domain is not removing it.
    ///
    /// If this ever fails, Apple changed the behaviour and the file deletion in
    /// `IsolatedDefaults.remove` has become redundant rather than load-bearing. Worth being told.
    func testEmptyingTheDomainAloneLeavesTheDomainBehind() throws {
        let name = IsolatedDefaults.name(for: "emptied")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set("value", forKey: "key")
        defaults.synchronize()

        defaults.removePersistentDomain(forName: name)
        defaults.synchronize()

        XCTAssertNil(defaults.string(forKey: "key"), "the domain is empty…")
        XCTAssertTrue(
            exists(name),
            "…and still on disk, so still counted — which is why emptying it is not enough")

        IsolatedDefaults.remove(named: name)
    }

    func testIsolatedDefaultsHandsBackAWorkingSuiteUnderTheSweepablePrefix() throws {
        let defaults = try isolatedDefaults("selfcheck")
        XCTAssertNil(defaults.string(forKey: "key"), "a suite must start empty, not inherit")

        defaults.set("value", forKey: "key")
        defaults.synchronize()
        XCTAssertEqual(defaults.string(forKey: "key"), "value", "and must be a real suite")

        let made = try FileManager.default
            .contentsOfDirectory(atPath: IsolatedDefaults.preferences.path)
            .filter { $0.hasPrefix("\(IsolatedDefaults.prefix)selfcheck-") }
        XCTAssertFalse(
            made.isEmpty,
            "the suite must land under the one anchored prefix a sweep looks for")
    }

    /// The safety property the sweep rests on: it only ever deletes something with nothing in it.
    ///
    /// Several checkouts share one `$HOME`, so the sweep can always run beside a live test in
    /// another process. This is what makes that harmless.
    func testTheSweepTakesEmptyHusksAndLeavesAnythingWithContentAlone() throws {
        let husk = IsolatedDefaults.name(for: "husk")
        let live = IsolatedDefaults.name(for: "live")
        try NSDictionary().write(to: IsolatedDefaults.url(for: husk))
        try NSDictionary(dictionary: ["key": "value"]).write(to: IsolatedDefaults.url(for: live))
        XCTAssertTrue(exists(husk) && exists(live), "precondition: both files are on disk")

        IsolatedDefaults.sweepStaleSuites()

        XCTAssertFalse(exists(husk), "an empty domain is residue and must be swept")
        XCTAssertTrue(
            exists(live),
            "a domain with contents may belong to a run in another checkout — never sweep it")

        IsolatedDefaults.remove(named: live)
    }

    /// The acceptance criterion that outlives this PR: *no test constructs a suite directly any
    /// more, so the next one added inherits the cleanup*.
    ///
    /// Reviewer attention is the only other thing enforcing that, and reviewer attention is what
    /// let 2,280 domains accumulate. Scanning the sources is unusual for a unit test; it is here
    /// because it is the only mechanism that catches the *next* person rather than this one.
    func testNoTestConstructsAUserDefaultsSuiteOutsideTheHelper() throws {
        let testsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Shared/
            .deletingLastPathComponent()  // HelmTests/
        let helper = testsRoot.appendingPathComponent("Shared/IsolatedDefaults.swift").path

        let files = try XCTUnwrap(
            FileManager.default.enumerator(atPath: testsRoot.path),
            "could not read \(testsRoot.path) — this guard must fail loudly, not skip")

        var offenders: [String] = []
        for case let relative as String in files where relative.hasSuffix(".swift") {
            let path = testsRoot.appendingPathComponent(relative).path
            guard path != helper, path != #filePath else { continue }
            let source = try String(contentsOfFile: path, encoding: .utf8)
            guard source.contains("UserDefaults(suiteName:") else { continue }
            offenders.append(relative)
        }

        XCTAssertEqual(
            offenders, [],
            """
            construct suites with `isolatedDefaults(_:)`, not `UserDefaults(suiteName:)` — \
            a suite made directly is never removed and leaks a `defaults domains` entry per run
            """)
    }
}
