import XCTest

@testable import Helm

/// `Subprocess` on its own. The deadline, cancellation and the cooperative-pool property are
/// proven through the callers that depend on them (`ArchonCLITests`, `WorktreeCLITests`), so this
/// covers what those do not reach directly.
final class SubprocessTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helm-subprocess-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A nonzero exit is a result, not a failure — `git merge-base --is-ancestor` answers with
    /// one — and both streams come back whole, from the directory the caller named.
    func testStatusBothStreamsAndTheWorkingDirectoryComeBack() async throws {
        let cwd = scratch.appendingPathComponent("cwd")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let result = try await Subprocess.run(
            ["/bin/sh", "-c", "printf 'out'; printf 'err' >&2; printf x > here; exit 3"],
            cwd: cwd.path, environment: [:], timeout: .seconds(20), scratch: scratch)

        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cwd.appendingPathComponent("here").path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["cwd"],
            "the capture files are removed once the call returns")
    }

    func testAnUnlaunchableChildIsALaunchFailure() async throws {
        do {
            _ = try await Subprocess.run(
                ["true"], cwd: scratch.appendingPathComponent("missing").path,
                environment: [:], timeout: .seconds(20), scratch: scratch)
            XCTFail("expected a launch failure")
        } catch let failure as Subprocess.Failure {
            guard case .launchFailed = failure else {
                return XCTFail("expected .launchFailed, got \(failure)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    func testTheStderrSnippetIsTrimmedAndBounded() {
        let result = Subprocess.Result(
            status: 1, stdout: Data(), stderr: Data("  \(String(repeating: "x", count: 10))\n".utf8)
        )
        XCTAssertEqual(result.stderrSnippet(limit: 20), String(repeating: "x", count: 10))
        XCTAssertEqual(result.stderrSnippet(limit: 4), "xxxx…")
    }

    func testDirectoriesLeadTheInheritedPath() {
        XCTAssertEqual(
            Subprocess.environment(
                inherited: ["PATH": "/usr/bin", "HOME": "/h"], prepending: ["/a"]),
            ["PATH": "/a:/usr/bin", "HOME": "/h"])
        XCTAssertEqual(
            Subprocess.environment(inherited: ["PATH": ""], prepending: ["/a"])["PATH"], "/a",
            "an empty inherited PATH leaves no trailing colon")
    }
}
