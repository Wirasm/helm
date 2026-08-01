import Foundation
import XCTest

/// The only way a test here gets a `UserDefaults`.
///
/// `UserDefaults(suiteName:)` writes a real file into `~/Library/Preferences`, and a domain is
/// listed in `defaults domains` for exactly as long as that file exists. Tests that made one and
/// walked away had left 2,280 of them on the development machine by the time #46 was filed —
/// noise in the middle of the persistence debugging session that is #45.
///
/// Two things about that are not obvious, and both were measured rather than assumed:
///
/// 1. **`removePersistentDomain(forName:)` does not remove a domain.** It empties it and leaves
///    the file, so the entry survives. `WorkspaceContextTests` called it faithfully in `tearDown`
///    and still accounted for 525 of those 2,280 — as empty plists rather than full ones, which
///    is invisible to any assertion about contents. Nothing in `UserDefaults` deletes the file;
///    only `FileManager` does.
///
/// 2. **A run cannot fully clean up after itself.** Teardown deletes the file and the file is
///    verifiably gone, and then cfprefsd re-materialises the emptied domain as a 42-byte husk a
///    second or two later, after the test process has gone. Nothing available from inside the
///    process prevents that — `removeSuite(named:)` on the suite or on `.standard`,
///    `synchronize()`, and `CFPreferencesAppSynchronize` were all tried and none of them do.
///
/// So cleanup is in two parts: teardown removes the *contents* immediately, and the next run
/// removes the husks the last one could not. The count is bounded at a single run's worth and
/// self-heals, instead of growing without bound. It is not zero, and that is a real limit — see
/// `sweepStaleSuites`.
enum IsolatedDefaults {
    /// One anchored prefix for every suite this target makes.
    ///
    /// The label lives inside it for provenance, so a sweep is a single pattern and cannot
    /// match the real `helm` and `com.wirasm.helm` domains sitting beside it in the same folder.
    static let prefix = "helm-tests-"

    static func name(for label: String) -> String { "\(prefix)\(label)-\(UUID().uuidString)" }

    /// Where a suite's backing file lives — the thing `defaults domains` is actually reading.
    static func url(for name: String) -> URL { preferences.appendingPathComponent("\(name).plist") }

    /// The folder `defaults domains` reads. The real `helm` and `com.wirasm.helm` live here too.
    static let preferences = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Preferences")

    /// Remove a suite so that `defaults domains` stops listing it.
    ///
    /// Both steps are load-bearing. Emptying the persistent domain first is what stops cfprefsd
    /// flushing a cached copy back over the deletion during the run; deleting the file is the
    /// only thing that removes the domain at all.
    static func remove(named name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// Delete husks left behind by earlier runs. Runs once per test process.
    ///
    /// **Only empty domains are removed, and that is the whole safety argument.** Several
    /// checkouts of helm share one `$HOME` — three worktrees were running `swift test` while
    /// this was written — so a sweep can always collide with a live run in another process.
    /// Deleting an *empty* plist cannot lose anything: there is nothing in it, and cfprefsd
    /// simply writes it again if that suite is still in use. A size or age heuristic would have
    /// no such guarantee.
    static func sweepStaleSuites() {
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: preferences.path)
        else { return }

        for file in names where file.hasPrefix(prefix) && file.hasSuffix(".plist") {
            let url = preferences.appendingPathComponent(file)
            guard let contents = NSDictionary(contentsOf: url), contents.count == 0 else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// `static let` so the sweep happens exactly once per process, on the first suite anyone asks
    /// for, without a bespoke `XCTestObservation` or a run-order dependency between test classes.
    private static let sweptOnce: Void = sweepStaleSuites()

    static func sweepOnce() { _ = sweptOnce }
}

extension XCTestCase {
    /// A `UserDefaults` suite that goes away with the test that asked for it.
    ///
    /// Cleanup registers here rather than in a `tearDown` override so it cannot be forgotten by
    /// the next test to want a suite, and so a class needs no stored property to hold the name.
    ///
    /// - Parameter label: What the suite is for. Kept in the name for provenance.
    func isolatedDefaults(
        _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> UserDefaults {
        IsolatedDefaults.sweepOnce()
        let name = IsolatedDefaults.name(for: label)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: name), "could not open suite \(name)", file: file, line: line)
        addTeardownBlock { IsolatedDefaults.remove(named: name) }
        return defaults
    }
}
