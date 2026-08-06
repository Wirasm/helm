import Foundation
import HelmWire
import XCTest

/// Proves the standalone spool scripts and `HelmWire` still agree on the wire format — the
/// detectable half of the duplication `AGENTS.md` argues is honest (#221).
///
/// **Why the duplication exists at all.** `tools/helm-spool.swift`, `helm-close.swift` and
/// `helm-capture.swift` cannot `import HelmWire`: a single-file `swift tools/…swift` script
/// resolves no `Package.swift` and runs from any cwd, which is the whole reason the spool is a
/// script rather than an SPM target (`AGENTS.md`'s "Why the spool is a script, and must stay
/// one" has the measurements). So the request JSON, the result JSON and the spool's own
/// directory-resolution rules are each spelled out twice — once here as `HelmWire` types and
/// functions, once by hand in each script. A duplicate is honest only when a runtime boundary
/// makes sharing impossible — this is that boundary — but honest still means it has to be
/// *watched*, not merely excused.
///
/// **This file covers three of the spool's four boundaries, and says which one it does not:**
///
/// 1. **The request direction** (script → helm): a script writes `<id>.json`, helm's
///    `SpoolDirectory.request(at:)` decodes it. Covered by the three `testHelm*WritesWhat
///    *RequestDecodes` tests below, unchanged from #221's first pass.
/// 2. **The result direction** (helm → script): helm writes `results/<id>.json`, the script
///    reads `json["status"] as? String` and switches on it by hand — `helm-spool.swift:180`,
///    `helm-close.swift:151`, `helm-capture.swift:148`, none of which decode through
///    `SpoolResult`. Covered by `testHelm*ExitCodeAndStderrForEveryResultStatus` below, over
///    **every** `SpoolResult.Status` case for every script — `Status: CaseIterable` plus an
///    exhaustive switch in `expectation(for:)` is what makes forgetting a script for a new
///    case a compile error in this file rather than a silent gap.
/// 3. **The directory-resolution rules** (`SpoolDirectory.resolve`, hand-duplicated as
///    `spoolRoot(_:)` in every script). The `HELM_SPOOL_DIR` override branch is exercised by
///    every test above, since that is how they all redirect a script at a temp directory. The
///    `HELM_DEFAULTS_SUITE` branch gets its own test,
///    `testHelmSpoolResolvesAnIsolatedSuiteExactlyLikeSpoolDirectory`, against a real,
///    uniquely-named suite under the real home directory (cleaned up after) — see that test's
///    header for why it cannot go through a temp directory the way everything else here does.
///
/// **What is not covered, and why:** the *default* resolution — no `HELM_SPOOL_DIR`, no
/// `HELM_DEFAULTS_SUITE` — which is the one case that cannot be redirected. `FileManager
/// .default.homeDirectoryForCurrentUser` (and `NSHomeDirectory()`) do not honour the `HOME`
/// environment variable on Darwin — measured directly: `env -i HOME=/tmp/fake PATH="$PATH"
/// swift -e 'print(FileManager.default.homeDirectoryForCurrentUser)'` still prints the real
/// account home. That leaves no way to exercise this branch via a real subprocess without it
/// resolving to the operator's actual `~/.helm/spool` — the spool a live helm on this machine
/// may be watching right now. Writing a spawn request into that directory as a side effect of
/// a unit test is not a risk this suite will take to close a coverage gap. The override and
/// isolated-suite branches above are the two a test can reach safely, and between them they
/// exercise the same `DefaultsSuite.override` decision the default branch also goes through —
/// just not the one case whose whole purpose is "no override, use my real spool."
///
/// **What this actually proves, and why it is stronger than a literal comparison.** Each test
/// runs the real script as a subprocess — the actual compiled Swift a caller would invoke, not
/// a description of it — against a temp `HELM_SPOOL_DIR` (or, for the suite test, a real but
/// disposable one), and decodes what it wrote, or reads its exit code and stderr, against the
/// real `HelmWire` types. A hand-typed JSON literal compared against another hand-typed literal
/// would only prove the test author's memory of the format agrees with itself; this proves the
/// script's actual behaviour is what `HelmWire` actually describes.
///
/// **Measured cost**: `swift tools/<script>.swift` compiles and runs each script fresh — around
/// 0.3–0.5s per invocation on this machine. The result-direction and suite tests add roughly
/// twenty more invocations; the whole file still finishes in a few seconds, not enough to move
/// this out of the ordinary gate.
final class SpoolWireConformanceTests: XCTestCase {
    private var spoolDir: URL!
    private var runningProcesses: [Process] = []

    override func setUpWithError() throws {
        spoolDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-spool-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
        try SpoolDirectory(root: spoolDir).prepare()
    }

    override func tearDownWithError() throws {
        // Every script that has NOT yet been given a terminal result keeps polling — nothing
        // in this suite is a real helm. Leaving one running would leak a process, and a hung
        // terminate() must not hang the suite with it. Harmless for scripts that have already
        // exited on their own: `isRunning` is false and the loop below is a no-op for them.
        for process in runningProcesses where process.isRunning {
            process.terminate()
        }
        for process in runningProcesses {
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        runningProcesses = []
        try? FileManager.default.removeItem(at: spoolDir)
        spoolDir = nil
    }

    // MARK: - 1. The request direction

    func testHelmSpoolWritesWhatSpawnRequestDecodes() throws {
        let id = "conformance-spawn"
        try run(
            "helm-spool.swift",
            [
                "/tmp", "--command", "claude", "--arg", "--model", "--arg", "opus",
                "--prompt", "hello from the conformance test", "--id", id,
            ])

        guard case .spawn(let spawn) = try decodedRequest(id: id) else {
            return XCTFail("helm-spool.swift wrote a request HelmWire did not decode as a spawn")
        }
        XCTAssertEqual(spawn.cwd, "/tmp")
        XCTAssertEqual(spawn.command, "claude")
        XCTAssertEqual(spawn.args, ["--model", "opus"])
        XCTAssertEqual(spawn.prompt, "hello from the conformance test")
    }

    func testHelmCloseWritesWhatCloseRequestDecodes() throws {
        let id = "conformance-close"
        let terminal = UUID()
        try run("helm-close.swift", [terminal.uuidString, "--force", "--id", id])

        guard case .close(let close) = try decodedRequest(id: id) else {
            return XCTFail("helm-close.swift wrote a request HelmWire did not decode as a close")
        }
        XCTAssertEqual(close.terminal, terminal.uuidString)
        XCTAssertTrue(close.force)
    }

    func testHelmCaptureWritesWhatCaptureRequestDecodes() throws {
        let id = "conformance-capture"
        try run(
            "helm-capture.swift",
            ["--out", "/tmp/conformance-capture.png", "--window", "helm-conformance", "--id", id])

        guard case .capture(let capture) = try decodedRequest(id: id) else {
            return XCTFail(
                "helm-capture.swift wrote a request HelmWire did not decode as a capture")
        }
        XCTAssertEqual(capture.path, "/tmp/conformance-capture.png")
        XCTAssertEqual(capture.window, "helm-conformance")
    }

    // MARK: - 2. The result direction

    /// What a script should do with a given `Status`, expressed as this file's own prediction
    /// of its hand-rolled switch — not imported from the script, since the whole point is that
    /// nothing can be. Exhaustive over `Status`, so the compiler forces every new case to be
    /// answered here for all three scripts at once.
    private struct ResultExpectation {
        let exitCode: Int32
        /// A substring rather than an exact match: the success messages interpolate a pid or a
        /// path this test also controls, but pinning every byte of a human-readable line is
        /// more brittle than the thing being protected against.
        let stderrContains: String
    }

    /// helm-spool.swift's own `Exit` enum, restated as the raw codes this test asserts against
    /// — ok=0, refused=3, failed=4, unclaimed=5, abandoned=6. `.started` is not terminal for
    /// this script (see `testHelmSpoolDoesNotExitOnAStartedResult`), so it has no expectation
    /// here.
    private func helmSpoolExpectation(for status: SpoolResult.Status) -> ResultExpectation? {
        switch status {
        case .started: return nil
        case .ready: return ResultExpectation(exitCode: 0, stderrContains: "")
        case .captured: return ResultExpectation(exitCode: 4, stderrContains: "unknown status")
        case .closed: return ResultExpectation(exitCode: 4, stderrContains: "unknown status")
        case .unclaimed: return ResultExpectation(exitCode: 5, stderrContains: "no mailbox")
        case .refused: return ResultExpectation(exitCode: 3, stderrContains: "not an agent")
        case .failed: return ResultExpectation(exitCode: 4, stderrContains: "could not act")
        case .abandoned: return ResultExpectation(exitCode: 6, stderrContains: "stopped mid-flight")
        }
    }

    /// helm-close.swift's own `Exit` enum — ok=0, refused=3, failed=4, abandoned=6. No
    /// `started` special case here: unlike the spawn script, a close is one write, not two
    /// (`SpoolResult.Status.closed`'s own header), so every non-`closed` status the script does
    /// not name falls to its `default:` branch.
    private func helmCloseExpectation(for status: SpoolResult.Status) -> ResultExpectation {
        switch status {
        case .started:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status started")
        case .ready:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status ready")
        case .captured:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status captured")
        case .closed:
            return ResultExpectation(exitCode: 0, stderrContains: "is gone")
        case .unclaimed:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status unclaimed")
        case .refused: return ResultExpectation(exitCode: 3, stderrContains: "not an agent")
        case .failed: return ResultExpectation(exitCode: 4, stderrContains: "could not act")
        case .abandoned: return ResultExpectation(exitCode: 6, stderrContains: "stopped mid-flight")
        }
    }

    /// helm-capture.swift's own `Exit` enum — ok=0, refused=3, failed=4, abandoned=6. Same
    /// shape as `helmCloseExpectation`: a capture is one write, so everything but `captured`
    /// falls to `default:`.
    private func helmCaptureExpectation(for status: SpoolResult.Status) -> ResultExpectation {
        switch status {
        case .started:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status started")
        case .ready:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status ready")
        case .captured:
            return ResultExpectation(exitCode: 0, stderrContains: "terminal content")
        case .closed:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status closed")
        case .unclaimed:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status unclaimed")
        case .refused: return ResultExpectation(exitCode: 3, stderrContains: "not an agent")
        case .failed: return ResultExpectation(exitCode: 4, stderrContains: "could not act")
        case .abandoned: return ResultExpectation(exitCode: 6, stderrContains: "stopped mid-flight")
        }
    }

    /// A plausible `SpoolResult` for one status — populated enough that a script's success path
    /// (`ready`, `closed`, `captured`) has everything it reads (`pid`, `capture.path`, …), and
    /// that its failure paths (`refused`, `failed`, `unclaimed`, `abandoned`) have a `reason`
    /// this test can look for in stderr.
    private func result(id: String, status: SpoolResult.Status, terminal: String) -> SpoolResult {
        switch status {
        case .started:
            return SpoolResult(id: id, status: .started, terminalId: terminal)
        case .ready:
            return SpoolResult(
                id: id, status: .ready, terminalId: terminal, pid: 4242, sessionId: "sess-1",
                handle: "helm-4242", runtime: "claude")
        case .captured:
            return SpoolResult(
                id: id, status: .captured,
                capture: CaptureReport(
                    path: "/tmp/conformance-result-capture.png", pixelWidth: 800,
                    pixelHeight: 600, scale: 2, window: "helm", terminalContent: .included,
                    terminalSurfaces: 1, terminalSurfacesExcluded: 0))
        case .closed:
            return SpoolResult(id: id, status: .closed, terminalId: terminal, pid: 4242)
        case .unclaimed:
            return SpoolResult(
                id: id, status: .unclaimed, terminalId: terminal, pid: 4242,
                reason: "no mailbox appeared before the deadline")
        case .refused:
            return SpoolResult(id: id, status: .refused, reason: "not an agent helm will start")
        case .failed:
            return SpoolResult(id: id, status: .failed, reason: "helm could not act on it")
        case .abandoned:
            return SpoolResult(
                id: id, status: .abandoned, reason: "helm stopped mid-flight and did not retry")
        }
    }

    func testHelmSpoolExitCodeAndStderrForEveryResultStatus() throws {
        for status in SpoolResult.Status.allCases {
            guard let expectation = helmSpoolExpectation(for: status) else { continue }
            let id = "spool-result-\(status.rawValue)"
            SpoolDirectory(root: spoolDir).write(result(id: id, status: status, terminal: id))

            let (exitCode, stderr) = try runAndCapture(
                "helm-spool.swift", ["/tmp", "--command", "claude", "--id", id])

            XCTAssertEqual(
                exitCode, expectation.exitCode,
                "helm-spool.swift on status \(status.rawValue): exit \(exitCode), stderr: \(stderr)"
            )
            if !expectation.stderrContains.isEmpty {
                XCTAssertTrue(
                    stderr.contains(expectation.stderrContains),
                    "helm-spool.swift on status \(status.rawValue): expected stderr to contain "
                        + "\"\(expectation.stderrContains)\", got \"\(stderr)\"")
            }
        }
    }

    /// The one non-terminal case: a spawn's own `Status.started` means "wait for the change",
    /// not "answer now" (`SpoolResult.Status`'s own header). Proving that means proving the
    /// *absence* of an exit within a bounded wait, which is a different shape from every other
    /// case above and does not fit `runAndCapture`.
    func testHelmSpoolDoesNotExitOnAStartedResult() throws {
        let id = "spool-result-started-is-not-terminal"
        SpoolDirectory(root: spoolDir).write(result(id: id, status: .started, terminal: id))
        try run("helm-spool.swift", ["/tmp", "--command", "claude", "--id", id])

        // Long enough for several poll cycles (helm-spool.swift polls every 0.25s) to prove
        // this is not surviving by accident.
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(
            runningProcesses.last?.isRunning ?? false,
            "helm-spool.swift must keep waiting on \"started\" — it exited instead")
        // tearDown kills it; this test only asserts it was still alive to kill.
    }

    func testHelmCloseExitCodeAndStderrForEveryResultStatus() throws {
        for status in SpoolResult.Status.allCases {
            let terminal = UUID()
            let id = "close-result-\(status.rawValue)"
            SpoolDirectory(root: spoolDir).write(
                result(id: id, status: status, terminal: terminal.uuidString))

            let (exitCode, stderr) = try runAndCapture(
                "helm-close.swift", [terminal.uuidString, "--id", id])

            let expectation = helmCloseExpectation(for: status)
            XCTAssertEqual(
                exitCode, expectation.exitCode,
                "helm-close.swift on status \(status.rawValue): exit \(exitCode), stderr: \(stderr)"
            )
            XCTAssertTrue(
                stderr.contains(expectation.stderrContains),
                "helm-close.swift on status \(status.rawValue): expected stderr to contain "
                    + "\"\(expectation.stderrContains)\", got \"\(stderr)\"")
        }
    }

    func testHelmCaptureExitCodeAndStderrForEveryResultStatus() throws {
        for status in SpoolResult.Status.allCases {
            let id = "capture-result-\(status.rawValue)"
            SpoolDirectory(root: spoolDir).write(result(id: id, status: status, terminal: id))

            let (exitCode, stderr) = try runAndCapture(
                "helm-capture.swift", ["--id", id])

            let expectation = helmCaptureExpectation(for: status)
            XCTAssertEqual(
                exitCode, expectation.exitCode,
                "helm-capture.swift on status \(status.rawValue): exit \(exitCode), stderr: \(stderr)"
            )
            XCTAssertTrue(
                stderr.contains(expectation.stderrContains),
                "helm-capture.swift on status \(status.rawValue): expected stderr to contain "
                    + "\"\(expectation.stderrContains)\", got \"\(stderr)\"")
        }
    }

    // MARK: - 3. Directory resolution — the HELM_DEFAULTS_SUITE branch

    /// `spoolRoot(_:)` in every script re-derives `SpoolDirectory.resolve`'s suite branch by
    /// hand — `AGENTS.md`'s architecture section names this the same honest duplicate as the
    /// wire format, and the same rule applies: it has to be watched.
    ///
    /// **Why this test cannot use `spoolDir` like everything else here.** The scripts have no
    /// way to be told "here is your home directory" — `HELM_SPOOL_DIR` is the *override* branch
    /// (already exercised by every test above, which is how they redirect a script at a temp
    /// directory in the first place), but the suite branch is reached only when
    /// `HELM_SPOOL_DIR` is **unset**, and at that point the script asks
    /// `FileManager.default.homeDirectoryForCurrentUser` directly. That call does not honour
    /// `$HOME` on Darwin (measured — see this file's header), so there is no way to sandbox it.
    ///
    /// **What makes this safe anyway.** The suite name is a UUID nothing else on this machine
    /// will ever ask for, so the directory it resolves to — a real
    /// `~/.helm/spool-<uuid>` — cannot collide with an isolated instance's real suite or the
    /// operator's default spool. It is created fresh and removed in this test alone.
    func testHelmSpoolResolvesAnIsolatedSuiteExactlyLikeSpoolDirectory() throws {
        let suite = "conformance-\(UUID().uuidString)"
        let expectedRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".helm/spool-\(suite)")
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".helm/spool-\(suite)"))
        }

        // `SpoolDirectory.resolve`'s own answer for the same suite — the thing the script's
        // hand-written copy has to agree with.
        XCTAssertEqual(
            SpoolDirectory.resolve(environment: [DefaultsSuite.suiteVariable: suite]).root.path,
            expectedRoot.path,
            "test setup is wrong if HelmWire itself does not resolve to the expected root")

        try FileManager.default.createDirectory(
            at: expectedRoot, withIntermediateDirectories: true)

        let id = "suite-resolution"
        let scriptURL = repositoryRoot.appendingPathComponent("tools/helm-spool.swift")
        var environment = ProcessInfo.processInfo.environment
        environment[SpoolDirectory.directoryVariable] = nil
        environment[SpoolDirectory.offVariable] = nil
        environment[DefaultsSuite.suiteVariable] = suite

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", scriptURL.path, "/tmp", "--command", "claude", "--id", id]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        runningProcesses.append(process)

        let directory = SpoolDirectory(root: expectedRoot)
        let url = expectedRoot.appendingPathComponent("\(id).json")
        let deadline = Date().addingTimeInterval(10)
        var request: SpoolRequest?
        while Date() < deadline, request == nil {
            request = directory.request(at: url)
            if request == nil { Thread.sleep(forTimeInterval: 0.02) }
        }

        guard case .spawn = request else {
            return XCTFail(
                "helm-spool.swift under HELM_DEFAULTS_SUITE=\(suite) did not write its request "
                    + "at \(url.path) — it resolved somewhere SpoolDirectory.resolve did not")
        }
    }

    // MARK: - Running the real script

    /// Launches `swift tools/<script> <arguments>` against `spoolDir`, and leaves it running —
    /// `tearDown` kills it once the test is done reading what it wrote. For the request
    /// direction, where the script never gets an answer and polls forever.
    private func run(_ script: String, _ arguments: [String]) throws {
        let scriptURL = repositoryRoot.appendingPathComponent("tools/\(script)")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw MissingScript(path: scriptURL.path)
        }

        var environment = ProcessInfo.processInfo.environment
        environment[SpoolDirectory.directoryVariable] = spoolDir.path
        environment[SpoolDirectory.offVariable] = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", scriptURL.path] + arguments
        process.environment = environment
        // The script's own progress lines on stderr are for a human at a terminal; this test
        // only cares about the file it wrote.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        runningProcesses.append(process)
    }

    /// Launches `swift tools/<script> <arguments>` against `spoolDir` and waits for it to exit
    /// — for the result direction, where a script that has been handed a terminal status is
    /// expected to answer and stop on its own. Captures stderr, since that is where every
    /// `die()` message and every success message lands.
    private func runAndCapture(
        _ script: String, _ arguments: [String], timeout: TimeInterval = 10
    ) throws -> (exitCode: Int32, stderr: String) {
        let scriptURL = repositoryRoot.appendingPathComponent("tools/\(script)")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw MissingScript(path: scriptURL.path)
        }

        var environment = ProcessInfo.processInfo.environment
        environment[SpoolDirectory.directoryVariable] = spoolDir.path
        environment[SpoolDirectory.offVariable] = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", scriptURL.path] + arguments
        process.environment = environment
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        runningProcesses.append(process)

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard !process.isRunning else {
            throw ScriptNeverExited(script: script, timeout: timeout)
        }
        // Reaps the process and populates terminationStatus; already confirmed not running
        // above, so this returns immediately rather than blocking.
        process.waitUntilExit()
        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Waits for `<spoolDir>/<id>.json` to appear, then decodes it exactly as
    /// `SpoolModel.drain()` does in the real app — `SpoolDirectory.request(at:)`, not a decoder
    /// hand-rolled for this test.
    ///
    /// Polling for the *final* name rather than reading as soon as anything shows up is what
    /// keeps this from ever reading a half-written file: every script writes under a dot name
    /// and renames into place, so the final name existing at all means the write is whole.
    private func decodedRequest(id: String, timeout: TimeInterval = 10) throws -> SpoolRequest {
        let directory = SpoolDirectory(root: spoolDir)
        let url = spoolDir.appendingPathComponent("\(id).json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let request = directory.request(at: url) {
                return request
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw RequestNeverAppeared(path: url.path, timeout: timeout)
    }

    private struct MissingScript: Error, CustomStringConvertible {
        let path: String
        var description: String { "expected a script at \(path) — nothing here to conform to" }
    }

    private struct RequestNeverAppeared: Error, CustomStringConvertible {
        let path: String
        let timeout: TimeInterval
        var description: String {
            "no request appeared at \(path) within \(timeout)s — the script did not write one, "
                + "or wrote one HelmWire's SpoolRequest could not decode"
        }
    }

    private struct ScriptNeverExited: Error, CustomStringConvertible {
        let script: String
        let timeout: TimeInterval
        var description: String {
            "\(script) was still running \(timeout)s after being given a terminal result — it "
                + "should have answered and exited"
        }
    }

    /// Four levels up from `Tests/HelmTests/Spool/`, the same walk `DefaultsDomainTests` and
    /// `SwiftPackageNameTests` do — this test reads a file (`tools/<script>`) no compiler
    /// touches, from a unit test that has to find it itself.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Spool/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }
}
