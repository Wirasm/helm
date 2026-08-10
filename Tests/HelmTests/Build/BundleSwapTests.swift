import XCTest

@testable import Helm

/// The swap script, run for real against disposable bundles.
///
/// **This is the one operation in helm that can destroy the operator's installed
/// application**, and until it was hoisted out of `BuildUpdateModel` into a constant it was
/// reachable only by actually replacing a live app — which meant nothing tested it. Everything
/// below runs `BundleSwap.script` itself, so the rollback and the deadline are measured rather
/// than argued for in a header.
///
/// `launcher:` is `/usr/bin/true` throughout: the script relaunches by running a command, and
/// a test must not put a fake bundle in front of LaunchServices.
final class BundleSwapTests: XCTestCase {
    private var scratch: URL!
    private var spawned: [Process] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Bounded rather than trusted: every process this suite starts is one it must not
        // leave spinning, which is #291's rule applied to a suite that deliberately starts a
        // live pid to wait on.
        for process in spawned where process.isRunning { process.terminate() }
        spawned = []
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
    }

    /// A bundle whose "contents" are one identifiable file, so a swap is visible by reading it.
    private func makeBundle(named name: String, marker: String) throws -> URL {
        let bundle = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: bundle.appendingPathComponent("marker"))
        return bundle
    }

    private func marker(of bundle: URL) -> String? {
        try? String(contentsOf: bundle.appendingPathComponent("marker"), encoding: .utf8)
    }

    @discardableResult
    private func swap(
        waitingFor pid: pid_t,
        installing product: URL,
        over target: URL,
        deadline: Int = 10
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = BundleSwap.arguments(
            waitingFor: pid,
            installing: product,
            over: target,
            deadline: deadline,
            launcher: "/usr/bin/true")
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A pid that has certainly exited, so the wait loop falls straight through.
    private func deadPID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    // MARK: - The happy path

    func testReplacesTheTargetOnceThePidIsGone() throws {
        let product = try makeBundle(named: "New.app", marker: "new")
        let target = try makeBundle(named: "Installed.app", marker: "old")

        let status = try swap(waitingFor: try deadPID(), installing: product, over: target)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(marker(of: target), "new", "the installed bundle was not replaced")
    }

    /// Nothing may be left beside the application: a `.helm-update` or `.helm-previous` that
    /// survives is a second copy of helm in /Applications that nobody asked for.
    func testLeavesNoResidueBesideTheTarget() throws {
        let product = try makeBundle(named: "New.app", marker: "new")
        let target = try makeBundle(named: "Installed.app", marker: "old")

        try swap(waitingFor: try deadPID(), installing: product, over: target)

        let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()
        XCTAssertEqual(entries, ["Installed.app", "New.app"])
    }

    /// Installing where nothing is yet — the target being absent is not a failure, it is a
    /// first install.
    func testInstallsWhenNothingIsThere() throws {
        let product = try makeBundle(named: "New.app", marker: "new")
        let target = scratch.appendingPathComponent("Installed.app")

        let status = try swap(waitingFor: try deadPID(), installing: product, over: target)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(marker(of: target), "new")
    }

    // MARK: - The failure that must not cost the operator their application

    /// **The rollback, which is the whole reason the script stages before it moves.** A
    /// product that cannot be copied must leave the installed bundle exactly as it was — not
    /// deleted, not half-written.
    func testKeepsTheInstalledBundleWhenTheProductCannotBeCopied() throws {
        let missing = scratch.appendingPathComponent("NeverBuilt.app")
        let target = try makeBundle(named: "Installed.app", marker: "old")

        let status = try swap(waitingFor: try deadPID(), installing: missing, over: target)

        XCTAssertNotEqual(status, 0, "a failed copy reported success")
        XCTAssertEqual(marker(of: target), "old", "a failed copy destroyed the installed bundle")
        let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()
        XCTAssertEqual(entries, ["Installed.app"], "a failed copy left residue behind")
    }

    // MARK: - The deadline

    /// A helper that waits forever on a pid that never dies is a process still spinning
    /// tomorrow — #291's lesson, and the reason the wait is bounded at all. It must give up
    /// **without** touching the installed bundle: helm is evidently still running, and the
    /// operator is still using it.
    func testGivesUpWhileTheProcessIsStillAlive() throws {
        let product = try makeBundle(named: "New.app", marker: "new")
        let target = try makeBundle(named: "Installed.app", marker: "old")

        // A live pid, bounded by its own argument rather than by this suite remembering to
        // kill it — the sleep exits on its own well inside the test's lifetime.
        let alive = Process()
        alive.executableURL = URL(fileURLWithPath: "/bin/sleep")
        alive.arguments = ["30"]
        try alive.run()
        spawned.append(alive)

        let started = Date()
        let status = try swap(
            waitingFor: alive.processIdentifier, installing: product, over: target, deadline: 1)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(status, 1, "the deadline did not produce its own exit code")
        XCTAssertLessThan(elapsed, 15, "the helper waited past its deadline")
        XCTAssertEqual(marker(of: target), "old", "the helper swapped while helm was still alive")
    }

    // MARK: - Arguments

    /// Paths reach the script as positional arguments, never as interpolated text — so a
    /// space or a quote in one is ordinary data rather than something to escape.
    func testPathsAreCarriedAsArgumentsNotInterpolated() {
        let arguments = BundleSwap.arguments(
            waitingFor: 4242,
            installing: URL(fileURLWithPath: "/tmp/a b/New.app"),
            over: URL(fileURLWithPath: "/tmp/c d/Installed.app"))
        XCTAssertEqual(arguments.first, "-c")
        XCTAssertEqual(arguments[1], BundleSwap.script)
        XCTAssertEqual(arguments[3], "4242")
        XCTAssertEqual(arguments[4], "/tmp/a b/New.app")
        XCTAssertEqual(arguments[5], "/tmp/c d/Installed.app")
        XCTAssertFalse(BundleSwap.script.contains("/tmp/a b"))
    }

    /// A bundle whose path contains a space really does swap — the argument-passing above,
    /// proved through the script rather than asserted about it.
    func testSwapsThroughAPathWithASpace() throws {
        let awkward = scratch.appendingPathComponent("a directory with spaces")
        try FileManager.default.createDirectory(at: awkward, withIntermediateDirectories: true)
        let product = awkward.appendingPathComponent("New.app")
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: product.appendingPathComponent("marker"))
        let target = awkward.appendingPathComponent("Installed App.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("marker"))

        let status = try swap(waitingFor: try deadPID(), installing: product, over: target)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(marker(of: target), "new")
    }
}
