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
        _ arguments: [String], environment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
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

    /// A bundle whose executable is a copy of a system binary, so it can be run and seen by `ps`.
    private func makeBundle(named name: String, executable: String = "/bin/sleep") throws -> URL {
        let bundle = scratch.appendingPathComponent(name)
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: executable), to: macOS.appendingPathComponent("Helm"))
        let plist: [String: Any] = ["CFBundleExecutable": "Helm"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    /// A binary that forks one child and both sleep 30s, so a fake helm can have a descendant.
    /// Compiled rather than copied: macOS kills a copy of `/bin/bash`, `/bin/sh` or
    /// `/usr/bin/time` on launch (exit 137), while a copy of `/bin/sleep` runs.
    private func forkingExecutable() throws -> URL {
        let source = scratch.appendingPathComponent("forker.c")
        let binary = scratch.appendingPathComponent("forker")
        try Data(
            "#include <unistd.h>\nint main(void) { fork(); sleep(30); return 0; }\n".utf8
        ).write(to: source)
        let compile = try bash([
            "-c", "xcrun clang \"$1\" -o \"$2\"", "cc", source.path, binary.path,
        ])
        XCTAssertEqual(compile.status, 0, compile.stderr)
        return binary
    }

    /// Runs an executable, bounded by its own sleep rather than by this suite remembering.
    private func run(_ executable: URL, _ arguments: [String] = ["30"]) throws -> pid_t {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
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

    // MARK: - Only a session inside that helm is resumed

    /// A session running somewhere other than the helm being quit would survive the quit, so the
    /// recipe would close every pane for nothing and then resume a second copy of it. Refused
    /// before anything detaches. The registry row lives under a scratch `HOME`.
    func testRefusesASessionThatIsNotInsideTheHelm() throws {
        let bundle = try makeBundle(named: "Target.app")
        _ = try run(bundle.appendingPathComponent("Contents/MacOS/Helm"))
        let elsewhere = try run(URL(fileURLWithPath: "/bin/sleep"))
        let session = "11111111-2222-3333-4444-555555555555"
        let home = scratch.appendingPathComponent("home")
        let sessions = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(#"{"pid":\#(elsewhere),"sessionId":"\#(session)"}"#.utf8)
            .write(to: sessions.appendingPathComponent("\(elsewhere).json"))

        let result = try bash(
            [script.path, session, scratch.path, "--bundle", bundle.path],
            environment: ["HOME": home.path])

        XCTAssertEqual(result.status, 3, result.stderr)
        XCTAssertTrue(result.stderr.contains("is not running inside helm"), result.stderr)
        XCTAssertFalse(result.stdout.contains("detached"), "it detached after refusing")
    }

    /// The control for the refusal above, through the same `check()`: a session in a child of
    /// the bundle's process passes the guard and is stopped only by the next check, a missing
    /// `cwd`. A guard that refused every session, or compared the pids the wrong way round,
    /// fails here.
    func testASessionInsideTheHelmPassesTheGuard() throws {
        let bundle = try makeBundle(named: "Target.app", executable: try forkingExecutable().path)
        let helm = try run(bundle.appendingPathComponent("Contents/MacOS/Helm"), [])
        var child = ""
        for _ in 0..<50 where child.isEmpty {
            child = try bash(["-c", "pgrep -P \(helm)"]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if child.isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        }
        XCTAssertFalse(child.isEmpty, "the child never started")
        let session = "11111111-2222-3333-4444-555555555555"
        let home = scratch.appendingPathComponent("home")
        let sessions = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(#"{"pid":\#(child),"sessionId":"\#(session)"}"#.utf8)
            .write(to: sessions.appendingPathComponent("\(child).json"))

        let result = try bash(
            [
                script.path, session, scratch.appendingPathComponent("absent").path,
                // The child runs the same executable, so the parent is named.
                "--bundle", bundle.path, "--pid", String(helm),
            ],
            environment: ["HOME": home.path])

        XCTAssertEqual(result.status, 3, result.stderr)
        XCTAssertTrue(result.stderr.contains("no directory"), result.stderr)
    }
}
