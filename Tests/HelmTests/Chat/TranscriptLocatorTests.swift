import XCTest

@testable import Helm

/// Registry row → transcript on disk. The row is the whole input: `sessionId`
/// names the file, `cwd` names the directory.
final class TranscriptLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-locator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func place(_ sessionId: String, inDirectoryNamed name: String) throws {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{}\n".write(
            to: directory.appendingPathComponent("\(sessionId).jsonl"),
            atomically: true, encoding: .utf8)
    }

    /// Claude Code's scheme, verified against the live store: every byte that is
    /// not an ASCII letter or digit becomes `-`.
    func testDirectoryNameMatchesClaudeCodesScheme() {
        XCTAssertEqual(
            TranscriptLocator.directoryName(for: "/Users/rasmus/Projects/mine/sild/helm"),
            "-Users-rasmus-Projects-mine-sild-helm")
        XCTAssertEqual(TranscriptLocator.directoryName(for: "/tmp/a_b.c"), "-tmp-a-b-c")
    }

    func testFindsTheTranscriptUnderTheDerivedDirectory() throws {
        try place("abc-123", inDirectoryNamed: "-tmp-ws")
        let session = AgentSession(pid: 1, cwd: "/tmp/ws", status: .idle, sessionId: "abc-123")

        XCTAssertEqual(
            TranscriptLocator.transcript(for: session, root: root)?.lastPathComponent,
            "abc-123.jsonl")
    }

    /// The slug is a lossy transform of a path helm did not choose, so a miss
    /// falls back to a scan. Guessing it wrong and "nothing written yet" look
    /// identical from the outside, and only one is worth reporting.
    func testFallsBackToScanningWhenTheDerivedDirectoryIsWrong() throws {
        try place("abc-123", inDirectoryNamed: "-somewhere-else-entirely")
        let session = AgentSession(pid: 1, cwd: "/tmp/ws", status: .idle, sessionId: "abc-123")

        XCTAssertEqual(
            TranscriptLocator.transcript(for: session, root: root)?.lastPathComponent,
            "abc-123.jsonl")
    }

    func testAnAgentThatHasWrittenNothingHasNoTranscript() {
        let session = AgentSession(pid: 1, cwd: "/tmp/ws", status: .busy, sessionId: "not-there")
        XCTAssertNil(TranscriptLocator.transcript(for: session, root: root))
    }

    /// A row with no `sessionId` names no file. pi publishes no registry at all,
    /// and a malformed row must resolve to nothing rather than to a guess.
    func testARowWithoutASessionIdResolvesToNothing() {
        let session = AgentSession(pid: 1, cwd: "/tmp/ws", status: .idle)
        XCTAssertNil(TranscriptLocator.transcript(for: session, root: root))
    }

    // MARK: - The registry field this depends on

    /// `sessionId` is decoded by the shared registry reader. The board does not
    /// use it; the chat face cannot locate a transcript without it.
    func testRegistryRowCarriesTheSessionId() throws {
        let row = """
            {"pid":42,"sessionId":"7b3277cb-4fcb","cwd":"/tmp/ws","status":"idle"}
            """
        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(row.utf8))
        XCTAssertEqual(decoded.sessionId, "7b3277cb-4fcb")
        XCTAssertEqual(decoded.status, .idle, "and the board's own fields still decode")
    }
}

/// The pid → row rule. The syscall half is separated out, so the rule itself is
/// exercisable with no process tree at all.
final class AgentLocatorTests: XCTestCase {
    private func row(_ pid: pid_t) -> AgentSession {
        AgentSession(pid: pid, cwd: "/tmp/ws", status: .idle, sessionId: "s\(pid)")
    }

    func testDirectPidMatchWins() {
        let picked = AgentLocator.session(
            in: [row(10), row(20)], forPid: 20, ancestors: [10])
        XCTAssertEqual(picked?.pid, 20, "an exact match is the agent, not its parent")
    }

    /// `claude` is not always the pty's foreground process — a shell function,
    /// `env`, or a wrapper script can sit in between.
    func testWalksToAnAncestorWhenTheForegroundProcessIsAWrapper() {
        let picked = AgentLocator.session(
            in: [row(10)], forPid: 99, ancestors: [55, 10])
        XCTAssertEqual(picked?.pid, 10)
    }

    func testNearestAncestorWinsOverAFurtherOne() {
        let picked = AgentLocator.session(
            in: [row(10), row(55)], forPid: 99, ancestors: [55, 10])
        XCTAssertEqual(picked?.pid, 55)
    }

    func testNoMatchIsAbsenceNotAGuess() {
        XCTAssertNil(AgentLocator.session(in: [row(10)], forPid: 99, ancestors: [55]))
    }

    /// The last resort: an agent launched *under* something that still owns the
    /// pty.
    func testFallsBackToADescendant() {
        let picked = AgentLocator.session(
            in: [row(77)], forPid: 99, ancestors: [], descendantsOf: { $0.pid == 77 })
        XCTAssertEqual(picked?.pid, 77)
    }

    /// **The walk must stop at helm's own pid.** Above helm is whatever launched
    /// it — very often the operator's own agent session, which an unbounded walk
    /// then reports as "the transcript of the terminal below". The spike hit
    /// exactly this and rendered a different conversation, indistinguishably.
    func testAncestorWalkNeverClimbsPastThisProcess() {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        // Walking up from our own parent must never reach us again, and must
        // never yield our own pid: the chain is what gets matched against the
        // registry, so our pid appearing in it is how a different conversation
        // gets rendered as "the terminal below".
        guard let parent = AgentLocator.parentPid(of: ownPid) else {
            return XCTFail("this process has a parent; sysctl should report it")
        }
        let chain = AgentLocator.ancestors(of: parent)
        XCTAssertFalse(chain.contains(ownPid), "the walk's ceiling is this process")
        XCTAssertLessThanOrEqual(chain.count, 16, "and it is bounded regardless")
    }

    func testAncestorWalkIsBoundedOnAPidThatDoesNotExist() {
        XCTAssertTrue(AgentLocator.ancestors(of: 999_999).isEmpty)
    }
}
