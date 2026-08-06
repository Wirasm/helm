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
/// one" has the measurements). So the request JSON is spelled out twice, once here as a
/// `Codable` type and once by hand in each script. A duplicate is honest only when a runtime
/// boundary makes sharing impossible — this is that boundary — but honest still means it has to
/// be *watched*, not merely excused.
///
/// **What this actually proves, and why it is stronger than a literal comparison.** Each test
/// runs the real script as a subprocess — the actual compiled Swift a caller would invoke, not
/// a description of it — against a temp `HELM_SPOOL_DIR`, and decodes the request it wrote with
/// the real `SpoolRequest`. A hand-typed JSON literal compared against another hand-typed literal
/// would only prove the test author's memory of the format agrees with itself; this proves the
/// script's actual output is the decoder's actual input, which is the one thing that matters.
///
/// **Measured cost**: `swift tools/<script>.swift` compiles and runs each script fresh — around
/// 0.3–0.5s per invocation on this machine, roughly a second added to the whole suite for all
/// three. Not enough to move this out of the ordinary gate.
final class SpoolWireConformanceTests: XCTestCase {
    private var spoolDir: URL!
    private var runningProcesses: [Process] = []

    override func setUpWithError() throws {
        spoolDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-spool-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Every one of these scripts writes its request and then polls for a result, which
        // never arrives here — nothing in this suite is a real helm. Leaving one running would
        // leak a process, and a hung terminate() must not hang the suite with it.
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

    // MARK: - Running the real script

    /// Launches `swift tools/<script> <arguments>` against `spoolDir`, and leaves it running —
    /// `tearDown` kills it once the test is done reading what it wrote.
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
