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
/// The resume itself is one `bench spawn`, and a test holds what it asks for against a stub
/// `bench`. The rest of the script quits, relaunches and restarts real processes, and is proved by
/// the isolated end-to-end run recorded on the PR, not here.
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

    /// A bundle whose executable is a copy of one of this suite's compiled stubs, so it can be run
    /// and seen by `ps` as a process running from inside the bundle.
    ///
    /// Never named `.app`, and sealed with an ad-hoc signature before anything runs from it (#439).
    /// The script reads `Contents/Info.plist`, and that file alone makes macOS treat the directory
    /// as a bundle whatever its suffix (`codesign -dv` says `Format=bundle`). A linker-signed stub
    /// in an unsealed bundle fails verification, so launching it made CoreServicesUIAgent put a
    /// "damaged and can't be opened" dialog on the operator's screen for every run.
    private func makeBundle(named name: String, executable: URL? = nil) throws -> URL {
        let bundle = scratch.appendingPathComponent(name)
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try executable ?? compiled.sleeper, to: macOS.appendingPathComponent("Helm"))
        let plist: [String: Any] = ["CFBundleExecutable": "Helm"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--sign", "-", "--force", bundle.path]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else { throw SealFailed(bundle: name) }
        return bundle
    }

    private struct SealFailed: Error {
        let bundle: String
    }

    // MARK: - Compiled stubs

    /// Every executable this suite launches is compiled here, never copied from `/bin`: AGENTS.md
    /// forbids copying an Apple system binary in a test (#409, #426). Compiled once per class run,
    /// removed with it.
    private struct Stubs {
        /// Sleeps 30s and exits: the fake helm, and a process running outside it.
        let sleeper: URL
        /// Forks one child and both sleep 30s, so a fake helm can have a descendant.
        let forker: URL

        static func compile(into directory: URL) throws -> Stubs {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            func stub(_ name: String, _ body: String) throws -> URL {
                let source = directory.appendingPathComponent("\(name).c")
                let binary = directory.appendingPathComponent(name)
                try Data("#include <unistd.h>\nint main(void) { \(body) }\n".utf8).write(to: source)
                let clang = Process()
                clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                clang.arguments = ["clang", source.path, "-o", binary.path]
                let err = Pipe()
                clang.standardError = err
                try clang.run()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                clang.waitUntilExit()
                guard clang.terminationStatus == 0 else {
                    throw CompileFailed(stub: name, stderr: String(decoding: stderr, as: UTF8.self))
                }
                return binary
            }
            return Stubs(
                sleeper: try stub("sleeper", "sleep(30); return 0;"),
                forker: try stub("forker", "fork(); sleep(30); return 0;"))
        }
    }

    private struct CompileFailed: Error, CustomStringConvertible {
        let stub: String
        let stderr: String
        var description: String { "could not compile the \(stub) stub: \(stderr)" }
    }

    // XCTest runs a class's `setUp`, its tests and its `tearDown` serially on one thread, so
    // nothing races on this.
    // The directory is held apart from the result so a compile that fails halfway is still
    // cleaned up.
    nonisolated(unsafe) private static var stubDirectory: URL?
    nonisolated(unsafe) private static var stubs: Result<Stubs, any Error>?

    override class func setUp() {
        super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-resume-stubs-\(UUID().uuidString)")
        stubDirectory = directory
        stubs = Result { try Stubs.compile(into: directory) }
    }

    override class func tearDown() {
        if let stubDirectory { try? FileManager.default.removeItem(at: stubDirectory) }
        stubDirectory = nil
        stubs = nil
        super.tearDown()
    }

    private var compiled: Stubs {
        get throws { try XCTUnwrap(Self.stubs).get() }
    }

    /// Runs an executable, bounded by its own sleep rather than by this suite remembering.
    private func run(_ executable: URL) throws -> pid_t {
        let process = Process()
        process.executableURL = executable
        try process.run()
        spawned.append(process)
        return process.processIdentifier
    }

    // MARK: - The swap is BundleSwap's

    /// Step 6 (M3): the session comes back in a benchd pty, in a pane of its own directory, with
    /// Remote Control and the notice as its next message, and under the bench suite when there is
    /// one. A stub `bench` records what it was asked; it is a shell script of our own, never a
    /// copied system binary.
    func testTheResumeIsOneBenchSpawnOfThatSession() throws {
        let bin = scratch.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let record = scratch.appendingPathComponent("argv")
        let stub = bin.appendingPathComponent("bench")
        try Data(
            "#!/bin/sh\necho \"suite=$BENCH_SUITE\" > \"\(record.path)\"\nfor a in \"$@\"; do echo \"$a\" >> \"\(record.path)\"; done\n"
                .utf8
        ).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let result = try bash([
            "-c",
            "source \"$1\"; bench_suite=trial remote_control=1; resume_in_bench \"$2\" 4b1c /tmp/w /tmp/n.md abc123",
            "test", script.path, bin.path,
        ])
        XCTAssertEqual(result.status, 0, result.stderr)

        let asked = try String(contentsOf: record, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(
            asked,
            [
                "suite=trial", "spawn", "--agent", "claude", "--cwd", "/tmp/w", "--resume", "4b1c",
                "--prompt-file", "/tmp/n.md", "--asked", "--arg", "--remote-control", "--arg",
                "helm abc123",
            ])
    }

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
        let bundle = try makeBundle(named: "Target.helm-test")
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
        let target = try makeBundle(named: "Target.helm-test")
        let other = try makeBundle(named: "Other.helm-test")
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
        let bundle = try makeBundle(named: "Target.helm-test")
        _ = try run(bundle.appendingPathComponent("Contents/MacOS/Helm"))
        let elsewhere = try run(try compiled.sleeper)
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
        let bundle = try makeBundle(named: "Target.helm-test", executable: try compiled.forker)
        let helm = try run(bundle.appendingPathComponent("Contents/MacOS/Helm"))
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
