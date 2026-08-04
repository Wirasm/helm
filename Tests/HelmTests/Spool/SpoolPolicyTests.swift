import XCTest

@testable import Helm

/// The gate on untrusted input, and the line helm composes once a request is through it.
///
/// A spool request is a *file*, so anything that can write a file is a caller. Every rule here
/// is what stands between that and a login shell with the operator's whole environment.
final class SpoolPolicyTests: XCTestCase {
    private func request(
        id: String = "req-1", cwd: String = "/tmp", command: String = "claude",
        args: [String] = [], prompt: String? = nil
    ) -> SpoolRequest {
        SpoolRequest(id: id, cwd: cwd, command: command, args: args, prompt: prompt)
    }

    private func accept(_ request: SpoolRequest) -> Result<AcceptedSpoolRequest, SpoolRefusal> {
        SpoolPolicy.accept(request, isDirectory: { $0 == "/tmp" || $0 == "/tmp/work" })
    }

    private func refusal(_ request: SpoolRequest) -> String? {
        if case .failure(let refusal) = accept(request) { return refusal.reason }
        return nil
    }

    func testAnAgentInAnExistingDirectoryIsAccepted() throws {
        let accepted = try accept(request(cwd: "/tmp/work/", prompt: "hello")).get()
        XCTAssertEqual(accepted.command, "claude")
        // Normalised through `Workspace`, so the request agrees with the workspace helm opens
        // for it — a trailing slash would otherwise be a second workspace for one folder.
        XCTAssertEqual(accepted.cwd, "/tmp/work")
        XCTAssertEqual(accepted.prompt, "hello")
    }

    func testOnlyAgentsMayBeStarted() {
        // The whole security story. `sh` in a login shell with the operator's environment is
        // what an ungated spool actually is.
        for command in ["sh", "bash", "zsh", "/bin/claude", "claude ", "Claude", "curl"] {
            XCTAssertNotNil(
                refusal(request(command: command)),
                "\(command) must not be startable from a file")
        }
        for command in SpoolPolicy.allowedCommands {
            XCTAssertNil(refusal(request(command: command)), "\(command) is an agent helm hosts")
        }
    }

    func testAnIdThatIsNotAFilenameIsRefused() {
        // `results/<id>.json` — an ungated id writes wherever the caller likes.
        for id in ["../../etc/passwd", "a/b", "", ".hidden", String(repeating: "x", count: 65)] {
            XCTAssertNotNil(refusal(request(id: id)), "\(id) must not name a result file")
        }
        XCTAssertNil(refusal(request(id: "spawn.2026-08-04_17-02-11")))
    }

    func testCwdMustBeAnAbsoluteDirectoryThatExists() {
        XCTAssertNotNil(refusal(request(cwd: "work")))
        XCTAssertNotNil(refusal(request(cwd: "/tmp/does-not-exist")))
    }

    func testArgumentsAreBoundedAndCarryNoControlCharacters() {
        XCTAssertNotNil(
            refusal(request(args: Array(repeating: "-x", count: SpoolPolicy.maxArgs + 1))))
        XCTAssertNotNil(refusal(request(args: ["--flag\nrm -rf /"])))
        XCTAssertNil(refusal(request(args: ["--dangerously-skip-permissions"])))
    }

    func testAnEmptyPromptIsNoPromptAtAll() throws {
        // Otherwise the line ends in `""`, which some agents read as an empty first turn.
        XCTAssertNil(try accept(request(prompt: "")).get().prompt)
    }

    // MARK: - The launch line

    func testThePromptIsReadFromAFileRatherThanTypedOntoTheCommandLine() {
        let accepted = AcceptedSpoolRequest(
            id: "r", cwd: "/tmp", command: "claude",
            args: ["--dangerously-skip-permissions"], prompt: "/review the diff")
        let line = SpoolLaunchLine.compose(accepted, promptPath: "/tmp/spool/prompts/r.txt")
        XCTAssertEqual(
            line,
            "'claude' '--dangerously-skip-permissions' \"$(cat '/tmp/spool/prompts/r.txt')\"")
        // A prompt beginning with `/`, or holding quotes or newlines, never reaches the shell's
        // word splitting — which is what makes all three ordinary rather than three hazards.
        XCTAssertFalse(line.contains("/review the diff"))
    }

    func testNoPromptMeansNoTrailingArgument() {
        let accepted = AcceptedSpoolRequest(
            id: "r", cwd: "/tmp", command: "pi", args: [], prompt: nil)
        XCTAssertEqual(SpoolLaunchLine.compose(accepted, promptPath: nil), "'pi'")
    }

    func testQuotingSurvivesAnEmbeddedSingleQuote() {
        // The only escaping rule a POSIX shell has no exceptions to: close, escape, reopen.
        XCTAssertEqual(SpoolLaunchLine.quoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(SpoolLaunchLine.quoted("; rm -rf /"), "'; rm -rf /'")
    }
}
