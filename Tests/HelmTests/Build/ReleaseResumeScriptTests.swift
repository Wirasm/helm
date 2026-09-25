import XCTest

@testable import Helm

/// `scripts/release-resume.sh`, sourced and run for real (#404).
///
/// Two things in that script can hurt the operator, and each gets a test here. The swap is
/// `BundleSwap.script`, read out of the Swift source at run time rather than copied, so the first
/// test holds the extraction equal to the compiled constant. The quit targets a pid, so the rest
/// hold the guard that refuses a pid not running from the bundle, which is what stands between a
/// wrong `--pid` and the operator's own helm.
///
/// The rest of the script quits, relaunches and resumes real processes, and is proved by the
/// isolated end-to-end run recorded on the PR, not here.
final class ReleaseResumeScriptTests: XCTestCase {
    private var scratch: URL!
    private var spawned: [Process] = []

    override func setUpWithError() throws {
        // Resolved, because the script compares pids by their real executable path and the
        // temporary directory is reached through /var → /private/var.
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        scratch = scratch.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        for process in spawned where process.isRunning { process.terminate() }
        spawned = []
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
    }

    private var script: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Build
            .deletingLastPathComponent()  // HelmTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("scripts/release-resume.sh")
    }

    private func bash(
        _ arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout, as: UTF8.self),
            String(decoding: stderr, as: UTF8.self)
        )
    }

    /// Call one of the script's functions.
    private func call(
        _ function: String, _ arguments: String...
    ) throws -> (
        status: Int32, stdout: String, stderr: String
    ) {
        // `$0` must not be the script's path, or sourcing it would run `main`.
        try bash(
            ["-c", "source \"$1\"; shift; \(function) \"$@\"", "test", script.path] + arguments)
    }

    /// A bundle whose executable is a copy of `/bin/sleep`, so it can be run and seen by `ps`.
    private func makeBundle(named name: String) throws -> URL {
        let bundle = scratch.appendingPathComponent(name)
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/sleep"), to: macOS.appendingPathComponent("Helm"))
        let plist: [String: Any] = ["CFBundleExecutable": "Helm"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    /// Runs an executable, bounded by its own argument rather than by this suite remembering.
    private func run(_ executable: URL) throws -> pid_t {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        spawned.append(process)
        return process.processIdentifier
    }

    // MARK: - The swap is BundleSwap's

    func testTheSwapItRunsIsBundleSwapsOwnScript() throws {
        let result = try call("swap_script")
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout, BundleSwap.script + "\n",
            "the script extracted from BundleSwap.swift is not the compiled BundleSwap.script")
    }

    // MARK: - Only the bundle's own helm is quit

    /// The control for the refusal below: a guard that refused every pid would pass that test
    /// alone, and would also make the recipe useless.
    func testFindsThePidRunningFromTheBundle() throws {
        let bundle = try makeBundle(named: "Target.app")
        let pid = try run(bundle.appendingPathComponent("Contents/MacOS/Helm"))

        let found = try call("resolve_helm_pid", bundle.path)
        XCTAssertEqual(found.status, 0, found.stderr)
        XCTAssertEqual(found.stdout.trimmingCharacters(in: .whitespacesAndNewlines), String(pid))

        let given = try call("resolve_helm_pid", bundle.path, String(pid))
        XCTAssertEqual(given.status, 0, given.stderr)
    }

    /// A `--pid` from another bundle (the operator's installed helm, when the target is a test
    /// copy) is refused before anything is detached or quit.
    func testRefusesAPidRunningFromAnotherBundle() throws {
        let target = try makeBundle(named: "Target.app")
        let other = try makeBundle(named: "Other.app")
        let pid = try run(other.appendingPathComponent("Contents/MacOS/Helm"))

        let result = try bash([
            script.path, "00000000-0000-0000-0000-000000000000", scratch.path,
            "--bundle", target.path, "--pid", String(pid),
        ])

        XCTAssertEqual(result.status, 3, result.stderr)
        XCTAssertTrue(result.stderr.contains("is not running from"), result.stderr)
        XCTAssertFalse(result.stdout.contains("detached"), "it detached after refusing")
        XCTAssertTrue(spawned[0].isRunning, "the refused pid was touched")
    }
}
