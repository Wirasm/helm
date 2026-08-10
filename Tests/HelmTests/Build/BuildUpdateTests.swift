import XCTest

@testable import Helm

/// The decision to show a badge, and the guards around the path it would install.
///
/// All of this is reachable without building an application, which is the reason
/// `BuildUpdate.decide` is a pure function over two values rather than something the model
/// works out while polling — the interesting cases here are "no identity" and "unreadable
/// stamp", and neither is a state anyone can produce on demand by rebuilding helm.
final class BuildUpdateTests: XCTestCase {
    private func stamp(sha: String, product: String = "/nowhere/Helm.app") -> BuildStamp {
        BuildStamp(sha: sha, builtAt: Date(timeIntervalSince1970: 1_000), product: product)
    }

    // MARK: - The four silences and the one offer

    func testNoStampOnDiskSaysNothing() {
        XCTAssertEqual(BuildUpdate.decide(running: "abc123", waiting: nil), .upToDate)
    }

    /// **The load-bearing silence.** A helm that cannot name its own commit — the SPM path,
    /// or any bundle built before stamping existed — must not badge, because the badge could
    /// never clear: every poll would compare nil against a stamp and offer an install that
    /// cannot change the answer.
    func testUnstampedBuildNeverBadges() {
        XCTAssertEqual(BuildUpdate.decide(running: nil, waiting: stamp(sha: "abc123")), .upToDate)
        XCTAssertEqual(BuildUpdate.decide(running: "", waiting: stamp(sha: "abc123")), .upToDate)
    }

    /// What makes the badge self-clearing: after a relaunch the new bundle's sha is the one
    /// that prompted it, so there is no state to reset and nothing to dismiss.
    func testSameCommitIsUpToDate() {
        XCTAssertEqual(
            BuildUpdate.decide(running: "abc123", waiting: stamp(sha: "abc123")), .upToDate)
    }

    func testDifferentCommitIsOffered() {
        let waiting = stamp(sha: "def456")
        XCTAssertEqual(BuildUpdate.decide(running: "abc123", waiting: waiting), .available(waiting))
        XCTAssertEqual(BuildUpdate.decide(running: "abc123", waiting: waiting).waiting, waiting)
    }

    /// helm has no idea whether a sha is ahead of or behind its own — that needs the checkout,
    /// which an installed app does not have. "Different" is the honest question and also the
    /// useful one: an agent building an older branch to test something has still produced a
    /// build worth offering.
    func testOlderCommitIsStillOffered() {
        let waiting = stamp(sha: "0000001")
        XCTAssertEqual(
            BuildUpdate.decide(running: "zzzzzz9", waiting: waiting), .available(waiting))
    }

    // MARK: - A stamp this build cannot read is a stamp it does not act on

    private func decode(_ json: String) -> BuildStamp? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BuildStamp.self, from: Data(json.utf8))
    }

    func testForeignFormatIsRefused() throws {
        let stamp = try XCTUnwrap(
            decode(
                """
                {"format":"helm.something-else","version":1,"sha":"abc123",
                 "builtAt":"2026-08-10T09:00:00Z","product":"/nowhere/Helm.app"}
                """))
        XCTAssertFalse(stamp.isReadable)
        XCTAssertEqual(BuildUpdate.decide(running: "zzz", waiting: stamp), .upToDate)
    }

    /// A *newer* version is as unreadable as an older one: helm cannot know what a field it
    /// has never heard of means, and guessing is how a reader misreports instead of failing.
    func testNewerVersionIsRefused() throws {
        let stamp = try XCTUnwrap(
            decode(
                """
                {"format":"helm.build-stamp","version":99,"sha":"abc123",
                 "builtAt":"2026-08-10T09:00:00Z","product":"/nowhere/Helm.app"}
                """))
        XCTAssertFalse(stamp.isReadable)
        XCTAssertEqual(BuildUpdate.decide(running: "zzz", waiting: stamp), .upToDate)
    }

    func testCurrentFormatRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = stamp(sha: "abc123")
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(BuildStamp.self, from: data)
        XCTAssertEqual(back, original)
        XCTAssertTrue(back.isReadable)
    }

    // MARK: - The product path is judged, never trusted

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("build-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMissingProductIsNotInstallable() {
        XCTAssertNil(stamp(sha: "a", product: "/nowhere/at/all/Helm.app").installableProduct)
    }

    /// An `.app` is a bundle. A regular file at that path is a truncated copy or something
    /// else entirely, and copying it over the running application would leave nothing to
    /// launch.
    func testFileAtTheProductPathIsNotInstallable() throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("Helm.app")
        try Data("not a bundle".utf8).write(to: file)
        XCTAssertNil(stamp(sha: "a", product: file.path).installableProduct)
    }

    /// The guard that stops a mis-set `product` turning the relaunch into "copy an arbitrary
    /// directory over the running application".
    func testDirectoryWithoutTheAppExtensionIsNotInstallable() throws {
        let root = try makeTemporaryDirectory()
        let directory = root.appendingPathComponent("Helm")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertNil(stamp(sha: "a", product: directory.path).installableProduct)
    }

    func testRealBundleIsInstallable() throws {
        let root = try makeTemporaryDirectory()
        let bundle = root.appendingPathComponent("Helm.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertEqual(
            stamp(sha: "a", product: bundle.path).installableProduct?.standardizedFileURL,
            bundle.standardizedFileURL)
    }

    // MARK: - Where the stamp is read from

    func testDirectoryVariableRedirectsTheStamp() {
        let directory = BuildStampDirectory.resolve(
            environment: [BuildStampDirectory.directoryVariable: "/tmp/helm-build-test"],
            home: URL(fileURLWithPath: "/Users/nobody"))
        XCTAssertEqual(directory.root.path, "/tmp/helm-build-test")
        XCTAssertEqual(directory.latest.lastPathComponent, "latest.json")
    }

    /// One location, no `build-<suite>` variant — a build is not per-instance, and the
    /// question a suite really raises is answered as policy in `BuildUpdateModel` instead.
    func testSuiteDoesNotSplitTheStampDirectory() {
        let home = URL(fileURLWithPath: "/Users/nobody")
        let plain = BuildStampDirectory.resolve(environment: [:], home: home)
        let isolated = BuildStampDirectory.resolve(
            environment: ["HELM_DEFAULTS_SUITE": "helm-bench"], home: home)
        XCTAssertEqual(plain.root.path, "/Users/nobody/.helm/build")
        XCTAssertEqual(isolated.root, plain.root)
    }

    func testUnreadableStampOnDiskReadsAsNothing() throws {
        let root = try makeTemporaryDirectory()
        let directory = BuildStampDirectory(root: root)
        try Data(
            """
            {"format":"helm.build-stamp","version":99,"sha":"abc123",
             "builtAt":"2026-08-10T09:00:00Z","product":"/nowhere/Helm.app"}
            """.utf8
        ).write(to: directory.latest)
        XCTAssertNil(directory.read())
    }

    func testMissingStampReadsAsNothing() throws {
        let root = try makeTemporaryDirectory()
        XCTAssertNil(BuildStampDirectory(root: root).read())
    }
}
