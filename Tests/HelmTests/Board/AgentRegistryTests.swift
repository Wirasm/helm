import XCTest

@testable import Helm

/// The registry read: the four-to-two status collapse, and the decode rules that
/// keep a surprising file from lighting a workspace that is fine.
///
/// Every case runs against a fixture directory, never the real `~/.claude/sessions`
/// — the board must be testable on a machine that has never run Claude Code.
final class AgentRegistryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-board-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func write(_ json: String, as name: String) throws {
        try json.write(
            to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// A registry row as Claude Code writes it — the real shape, trimmed to the
    /// fields the board reads plus enough noise to prove the decode ignores it.
    private func row(pid: Int, status: String?, cwd: String = "/tmp/ws") -> String {
        let statusField = status.map { "\"status\":\"\($0)\"," } ?? ""
        return """
            {"pid":\(pid),"sessionId":"7b3277cb-4fcb-4df0-a452-d30059772818",\
            "cwd":"\(cwd)","startedAt":1785596614353,"version":"2.1.220",\
            "kind":"interactive","entrypoint":"cli","name":"helm-8f",\
            \(statusField)"updatedAt":1785596922634,"statusUpdatedAt":1785596922634,\
            "bridgeSessionId":null}
            """
    }

    // MARK: - The collapse

    func testStatusCollapsesFourValuesToTwo() {
        XCTAssertTrue(AgentStatus.busy.isWorking)
        XCTAssertTrue(AgentStatus.shell.isWorking)
        XCTAssertFalse(AgentStatus.idle.isWorking, "finished — it is your turn")
        XCTAssertFalse(AgentStatus.waiting.isWorking, "blocked — the same state seen twice")
    }

    // MARK: - Decode

    /// `sessionId` is decoded alongside the board's own three fields. The board
    /// does not read it — the chat face does, because `sessionId` + `cwd` are
    /// what locate the transcript on disk. One registry row type, per #28.
    func testDecodesTheFieldsTheBoardReads() throws {
        try write(row(pid: 9139, status: "busy", cwd: "/Users/x/ws"), as: "9139.json")

        let sessions = AgentRegistry.sessions(in: root)

        XCTAssertEqual(
            sessions,
            [
                AgentSession(
                    pid: 9139, cwd: "/Users/x/ws", status: .busy,
                    sessionId: "7b3277cb-4fcb-4df0-a452-d30059772818")
            ])
    }

    func testRowWithoutStatusDecodesToNoStatus() throws {
        try write(row(pid: 9139, status: nil), as: "9139.json")

        let sessions = AgentRegistry.sessions(in: root)

        XCTAssertEqual(sessions.count, 1, "the row still decodes — only its status is absent")
        XCTAssertNil(sessions.first?.status, "no status key, nothing truthful to show")
    }

    func testUnrecognisedStatusDecodesToNoStatus() throws {
        try write(row(pid: 9139, status: "compacting"), as: "9139.json")

        let sessions = AgentRegistry.sessions(in: root)

        XCTAssertEqual(sessions.count, 1, "an unknown status must not take the row down with it")
        XCTAssertNil(
            sessions.first?.status,
            "a newer Claude Code must not be able to light a tab this build cannot read")
    }

    // MARK: - The scan

    func testMalformedFileCostsItsOwnRowAndNothingElse() throws {
        try write("{ this is not json", as: "1.json")
        try write(row(pid: 9139, status: "idle"), as: "9139.json")

        XCTAssertEqual(AgentRegistry.sessions(in: root).map(\.pid), [9139])
    }

    func testRowWithoutAPidIsDropped() throws {
        try write(#"{"cwd":"/tmp/ws","status":"busy"}"#, as: "orphan.json")

        XCTAssertEqual(
            AgentRegistry.sessions(in: root), [], "there is no board row without a pid to match")
    }

    func testNonJSONEntriesAreIgnored() throws {
        try write(row(pid: 9139, status: "busy"), as: "9139.json")
        try write("scratch", as: "notes.txt")

        XCTAssertEqual(AgentRegistry.sessions(in: root).map(\.pid), [9139])
    }

    func testMissingRegistryDirectoryYieldsNoRows() {
        let absent = root.appendingPathComponent("never-created")

        XCTAssertEqual(
            AgentRegistry.sessions(in: absent), [],
            "Claude Code has never run here — that is absence, not an error")
    }

    func testEmptyRegistryYieldsNoRows() {
        XCTAssertEqual(AgentRegistry.sessions(in: root), [])
    }

    // MARK: - One rule for a duplicate pid

    /// **The contract is that every reader picks the same row, not which row it picks.**
    ///
    /// Claude Code names the file after the pid, so two rows carrying one pid means two files
    /// claiming the same process — they cannot both be true and neither is more credible.
    /// `contentsOfDirectory` promises no order, so *which* one survives is not assertable and
    /// is not the point. What is: `sessionLookup` and `rows` are two callers of one question,
    /// and they must not answer it differently.
    ///
    /// This is the case that was missing when the two disagreed. `rows` uniqued last-wins while
    /// `sessionLookup` did its own `first { $0.pid == pid }`, so `snapshot.json` could attribute
    /// one session to a pane while that pane's own persisted `ResumableAgent` named another —
    /// silently, with each path confident. Caught by review rather than by a red test, which is
    /// why this test exists.
    func testEveryReaderResolvesADuplicatePidToTheSameRow() throws {
        try write(rowNamed(pid: 4242, session: "aaaa-1111"), as: "4242.json")
        try write(rowNamed(pid: 4242, session: "bbbb-2222"), as: "4242-stale.json")

        let byRow = AgentRegistry.rows(in: root)[4242]?.sessionId
        let byLookup = AgentRegistry.sessionLookup(in: root)(4242)

        XCTAssertNotNil(byRow, "one of them wins — the degenerate case is not absence")
        XCTAssertEqual(
            byRow, byLookup,
            "one rule, one answer: a pane's snapshot owner and its persisted resume record "
                + "must not name two different sessions")
    }

    private func rowNamed(pid: Int, session: String) -> String {
        """
        {"pid":\(pid),"sessionId":"\(session)","cwd":"/tmp/ws","status":"busy"}
        """
    }
}
