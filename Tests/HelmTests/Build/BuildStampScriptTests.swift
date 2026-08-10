import XCTest

@testable import Helm

/// The two shell scripts, run for real and checked against the Swift that reads them.
///
/// **Why this suite exists.** `scripts/stamp-build.sh` writes an Info.plist key that
/// `RunningBuild` reads, and `scripts/announce-build.sh` writes a JSON document that
/// `BuildStamp` decodes. Neither script can `import Helm` — one runs inside an Xcode build
/// phase and the other from a Makefile, both outside any Swift target — so the format is
/// spelled twice, in Swift and in shell. That is the same runtime-boundary carve-out AGENTS.md
/// grants the spool scripts and the mailbox, and it comes with the same obligation: the
/// duplication must be **detectable** rather than trusted.
///
/// So this runs the real scripts as subprocesses and decodes their output with the real types.
/// Rename `HelmBuildSHA` on either side, change a JSON field, or drop the atomic write, and a
/// test goes red instead of helm quietly losing the ability to ever see an update — a failure
/// whose only symptom is a badge that never appears, which nobody would think to go looking
/// for.
final class BuildStampScriptTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("build-stamp-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
    }

    /// The repo root, from this file's own path — the tests run from an unpredictable cwd.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Build
            .deletingLastPathComponent()  // HelmTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    @discardableResult
    private func run(
        _ script: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments =
            [repositoryRoot.appendingPathComponent("scripts/\(script)").path]
            + arguments
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A bundle shaped like a built product: `Contents/Info.plist`, optionally stamped.
    ///
    /// Spells the key as `RunningBuild.shaKey` rather than retyping it. A literal here would
    /// be a third copy of the name — and one that keeps this file green while the two real
    /// halves disagree, which is the exact failure the suite exists to catch.
    private func makeBundle(sha: String?) throws -> URL {
        let bundle = scratch.appendingPathComponent("Helm.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var entries = ""
        if let sha {
            entries = "<key>\(RunningBuild.shaKey)</key><string>\(sha)</string>"
        }
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>\(entries)</dict></plist>
            """.utf8
        ).write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    // MARK: - announce-build.sh writes what BuildStamp decodes

    func testAnnouncedStampDecodesWithTheRealType() throws {
        let bundle = try makeBundle(sha: "abc1234")
        let stampDirectory = scratch.appendingPathComponent("stamps")
        let result = try run(
            "announce-build.sh",
            arguments: [bundle.path],
            environment: [BuildStampDirectory.directoryVariable: stampDirectory.path])
        XCTAssertEqual(result.status, 0, "announce-build.sh failed: \(result.stderr)")

        let directory = BuildStampDirectory(root: stampDirectory)
        let stamp = try XCTUnwrap(
            directory.read(),
            "announce-build.sh wrote a stamp BuildStamp did not decode")
        XCTAssertEqual(stamp.sha, "abc1234")
        XCTAssertEqual(stamp.product, bundle.path)
        XCTAssertTrue(stamp.isReadable)
        // The bundle really is on disk, so the guard that gates the relaunch passes on a
        // genuine announcement — the negative cases are in `BuildUpdateTests`.
        XCTAssertNotNil(stamp.installableProduct)
        // A timestamp from `date -u` must survive the ISO8601 decoder the reader installs.
        XCTAssertEqual(stamp.builtAt.timeIntervalSinceNow, 0, accuracy: 300)
    }

    /// The whole point of the feature, end to end and in the right direction: an announced
    /// build that differs from the running one is offered, and the same one is not.
    func testAnnouncedStampDrivesTheDecision() throws {
        let bundle = try makeBundle(sha: "def5678")
        let stampDirectory = scratch.appendingPathComponent("stamps")
        try run(
            "announce-build.sh",
            arguments: [bundle.path],
            environment: [BuildStampDirectory.directoryVariable: stampDirectory.path])
        let waiting = BuildStampDirectory(root: stampDirectory).read()
        XCTAssertEqual(BuildUpdate.decide(running: "def5678", waiting: waiting), .upToDate)
        XCTAssertEqual(
            BuildUpdate.decide(running: "abc1234", waiting: waiting),
            .available(try XCTUnwrap(waiting)))
    }

    /// The permissions the stamp inherits from the spool and the bench snapshot: a 0700
    /// directory and a 0600 file.
    func testAnnouncedStampIsPrivate() throws {
        let bundle = try makeBundle(sha: "abc1234")
        let stampDirectory = scratch.appendingPathComponent("stamps")
        try run(
            "announce-build.sh",
            arguments: [bundle.path],
            environment: [BuildStampDirectory.directoryVariable: stampDirectory.path])
        let directory = BuildStampDirectory(root: stampDirectory)
        let directoryMode =
            try FileManager.default.attributesOfItem(
                atPath: directory.root.path)[.posixPermissions] as? NSNumber
        let fileMode =
            try FileManager.default.attributesOfItem(
                atPath: directory.latest.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.int16Value, 0o700)
        XCTAssertEqual(fileMode?.int16Value, 0o600)
    }

    /// No leftover `.tmp.<pid>` beside the stamp: the write is staged and moved, because a
    /// reader that polls this path must never see half of it.
    func testAnnounceLeavesNoStagingFileBehind() throws {
        let bundle = try makeBundle(sha: "abc1234")
        let stampDirectory = scratch.appendingPathComponent("stamps")
        try run(
            "announce-build.sh",
            arguments: [bundle.path],
            environment: [BuildStampDirectory.directoryVariable: stampDirectory.path])
        let entries = try FileManager.default.contentsOfDirectory(atPath: stampDirectory.path)
        XCTAssertEqual(entries, ["latest.json"])
    }

    /// An unstamped bundle announces nothing rather than announcing an empty sha — which
    /// `BuildUpdate` would then compare against and offer.
    func testUnstampedBundleAnnouncesNothing() throws {
        let bundle = try makeBundle(sha: nil)
        let stampDirectory = scratch.appendingPathComponent("stamps")
        let result = try run(
            "announce-build.sh",
            arguments: [bundle.path],
            environment: [BuildStampDirectory.directoryVariable: stampDirectory.path])
        XCTAssertEqual(result.status, 0)
        XCTAssertNil(BuildStampDirectory(root: stampDirectory).read())
    }

    func testMissingProductIsAnError() throws {
        let result = try run(
            "announce-build.sh",
            arguments: [scratch.appendingPathComponent("nothing-here.app").path],
            environment: [
                BuildStampDirectory.directoryVariable: scratch.appendingPathComponent("stamps").path
            ])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stderr.contains("not a bundle"), result.stderr)
    }

    // MARK: - stamp-build.sh writes the key RunningBuild reads

    /// **The spelling check.** `RunningBuild.shaKey` and the `PlistBuddy` line in
    /// `stamp-build.sh` are the two halves of one name; this is what makes renaming either of
    /// them fail loudly.
    func testStampWritesTheKeyRunningBuildReads() throws {
        let buildDirectory = scratch.appendingPathComponent("Build")
        let plistPath = "Helm.app/Contents/Info.plist"
        let plist = buildDirectory.appendingPathComponent(plistPath)
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict/></plist>
            """.utf8
        ).write(to: plist)

        let result = try run(
            "stamp-build.sh",
            environment: [
                "TARGET_BUILD_DIR": buildDirectory.path,
                "INFOPLIST_PATH": plistPath,
                "SRCROOT": repositoryRoot.path,
            ])
        XCTAssertEqual(result.status, 0, "stamp-build.sh failed: \(result.stderr)")

        let written = try XCTUnwrap(
            NSDictionary(contentsOf: plist)?[RunningBuild.shaKey] as? String,
            "stamp-build.sh did not write the key RunningBuild.shaKey names")
        XCTAssertFalse(written.isEmpty)

        // It is this repository's actual commit — the identity the whole comparison rests on.
        let head = try headSHA()
        XCTAssertTrue(
            written == head || written == "\(head)-dirty",
            "stamped \(written), expected \(head) (optionally -dirty)")
    }

    /// Stamping twice must land on one value, not append a second key — the second build of a
    /// commit has to carry that commit's identity, not the previous one's.
    func testStampingIsIdempotent() throws {
        let buildDirectory = scratch.appendingPathComponent("Build")
        let plistPath = "Helm.app/Contents/Info.plist"
        let plist = buildDirectory.appendingPathComponent(plistPath)
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>\
            <key>HelmBuildSHA</key><string>staleeee</string></dict></plist>
            """.utf8
        ).write(to: plist)

        let environment = [
            "TARGET_BUILD_DIR": buildDirectory.path,
            "INFOPLIST_PATH": plistPath,
            "SRCROOT": repositoryRoot.path,
        ]
        try run("stamp-build.sh", environment: environment)
        try run("stamp-build.sh", environment: environment)

        let written = try XCTUnwrap(
            NSDictionary(contentsOf: plist)?[RunningBuild.shaKey] as? String)
        XCTAssertNotEqual(written, "staleeee", "a rebuild kept the previous commit's identity")
        XCTAssertTrue(written.hasPrefix(try headSHA()))
    }

    /// A tree with no git still has to build — it just produces an app that never offers an
    /// update, which is what `BuildUpdate.decide` does with a nil sha.
    func testNoRepositoryStampsNothingAndSucceeds() throws {
        let buildDirectory = scratch.appendingPathComponent("Build")
        let plistPath = "Helm.app/Contents/Info.plist"
        let plist = buildDirectory.appendingPathComponent(plistPath)
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict/></plist>
            """.utf8
        ).write(to: plist)
        let notARepository = scratch.appendingPathComponent("bare")
        try FileManager.default.createDirectory(
            at: notARepository, withIntermediateDirectories: true)

        let result = try run(
            "stamp-build.sh",
            environment: [
                "TARGET_BUILD_DIR": buildDirectory.path,
                "INFOPLIST_PATH": plistPath,
                "SRCROOT": notARepository.path,
                // `git` walks upward, and the scratch directory may sit under one. This is the
                // supported way to say "stop here" and is what makes the negative reachable.
                "GIT_CEILING_DIRECTORIES": scratch.path,
            ])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertNil(NSDictionary(contentsOf: plist)?[RunningBuild.shaKey])
        XCTAssertTrue(result.stderr.contains("no git commit"), result.stderr)
    }

    private func headSHA() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryRoot.path, "rev-parse", "--short", "HEAD"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
