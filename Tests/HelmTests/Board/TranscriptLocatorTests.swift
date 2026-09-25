import XCTest

@testable import Helm

/// Session id and cwd → transcript on disk. `sessionId` names the file, `cwd` names the
/// directory. `AgentObserver` and the resume offer (#63) ask it.
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

        XCTAssertEqual(
            TranscriptLocator.transcript(forSession: "abc-123", cwd: "/tmp/ws", root: root)?
                .lastPathComponent,
            "abc-123.jsonl")
    }

    /// The slug is a lossy transform of a path helm did not choose, so a miss
    /// falls back to a scan. Guessing it wrong and "nothing written yet" look
    /// identical from the outside, and only one is worth reporting.
    func testFallsBackToScanningWhenTheDerivedDirectoryIsWrong() throws {
        try place("abc-123", inDirectoryNamed: "-somewhere-else-entirely")

        XCTAssertEqual(
            TranscriptLocator.transcript(forSession: "abc-123", cwd: "/tmp/ws", root: root)?
                .lastPathComponent,
            "abc-123.jsonl")
    }

    func testAnAgentThatHasWrittenNothingHasNoTranscript() {
        XCTAssertNil(
            TranscriptLocator.transcript(forSession: "not-there", cwd: "/tmp/ws", root: root))
    }

    /// An empty session id names no file, and must resolve to nothing rather than to
    /// whatever `.jsonl` the scan happens to find first.
    func testAnEmptySessionIdResolvesToNothing() throws {
        try place("", inDirectoryNamed: "-tmp-ws")
        XCTAssertNil(TranscriptLocator.transcript(forSession: "", cwd: "/tmp/ws", root: root))
    }

    // MARK: - The registry field this depends on

    /// `sessionId` is decoded by the shared registry reader. The board does not
    /// use it; the resume record (#63) and the spool's owner join cannot work without it.
    func testRegistryRowCarriesTheSessionId() throws {
        let row = """
            {"pid":42,"sessionId":"7b3277cb-4fcb","cwd":"/tmp/ws","status":"idle"}
            """
        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(row.utf8))
        XCTAssertEqual(decoded.sessionId, "7b3277cb-4fcb")
        XCTAssertEqual(decoded.status, .idle, "and the board's own fields still decode")
    }
}

/// The ancestor walk the spool and the canvas-note courier use to tie a process to the
/// pane it runs in.
final class AgentLocatorTests: XCTestCase {
    /// **The walk must stop at helm's own pid.** Above helm is whatever launched
    /// it — very often the operator's own agent session, which an unbounded walk
    /// then reports as an agent in the terminal below. The chat spike hit exactly
    /// this and rendered a different conversation, indistinguishably.
    func testAncestorWalkNeverClimbsPastThisProcess() {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        // Walking up from our own parent must never reach us again, and must
        // never yield our own pid: the chain is what gets matched against the
        // registry, so our pid appearing in it is how a different agent gets
        // attributed to "the terminal below".
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
