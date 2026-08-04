import XCTest

@testable import Helm

/// The watcher half, end to end, without a window, a ghostty surface or a pty.
///
/// #54 asks for exactly this — *"the watcher logic is reachable from `swift test`"* — because
/// three defects in two days came from logic trapped in a `View`. `SpoolSpawning` is the seam
/// that makes it possible: everything on the far side of it needs a real terminal, and nothing
/// on this side does.
///
/// **Nothing here races the thing it waits for.** Every wait is on an observable (a result file
/// with a given status) with a budget far longer than the work takes, which is the shape the
/// two flaky process-spawning tests in this repo (#157, and one fixed in PR #155) both got
/// wrong by assuming a fixed 300 ms was enough.
@MainActor
final class SpoolModelTests: XCTestCase {
    private var directory: SpoolDirectory!
    private var mailRoot: URL!
    private var spawner: FakeSpawner!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-spool-model-\(UUID().uuidString)")
        directory = SpoolDirectory(root: base.appendingPathComponent("spool"))
        mailRoot = base.appendingPathComponent("mail")
        try directory.prepare()
        try FileManager.default.createDirectory(at: mailRoot, withIntermediateDirectories: true)
        spawner = FakeSpawner()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory.root.deletingLastPathComponent())
        directory = nil
        mailRoot = nil
        spawner = nil
    }

    // MARK: - Fixtures

    private func model(
        claimDeadline: Duration = .seconds(3), isOff: Bool = false
    ) -> SpoolModel {
        let model = SpoolModel(
            directory: directory, mailRoot: mailRoot, isOff: isOff,
            shellDeadline: .seconds(5), claimDeadline: claimDeadline)
        model.attach(spawner: spawner)
        return model
    }

    @discardableResult
    private func submit(_ json: String, named name: String = "r.json") throws -> URL {
        let url = directory.root.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func request(
        id: String = "r", command: String = "claude", prompt: String? = nil
    )
        -> String
    {
        let cwd = FileManager.default.temporaryDirectory.path
        let promptField = prompt.map { ",\"prompt\":\"\($0)\"" } ?? ""
        return #"{"id":"\#(id)","cwd":"\#(cwd)","command":"\#(command)"\#(promptField)}"#
    }

    private func mailbox(_ handle: String, pid: pid_t, sessionId: String) throws {
        let dir = mailRoot.appendingPathComponent(handle)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try
            #"{"handle":"\#(handle)","runtime":"claude","pid":\#(pid),"sessionId":"\#(sessionId)","cwd":"/tmp"}"#
            .write(to: dir.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)
    }

    /// Wait for the answer to reach a state, or give up loudly. The budget is the test's, not
    /// the model's — it has to outlast the model's own deadlines.
    private func awaitResult(
        id: String = "r", is status: SpoolResult.Status, within budget: Duration = .seconds(20),
        file: StaticString = #filePath, line: UInt = #line
    ) async -> SpoolResult? {
        let expiry = ContinuousClock.now.advanced(by: budget)
        while ContinuousClock.now < expiry {
            if let result = directory.result(id: id), result.status == status { return result }
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTFail(
            "no \(status.rawValue) result for \(id) within \(budget) — last was "
                + String(describing: directory.result(id: id)?.status),
            file: file, line: line)
        return nil
    }

    // MARK: - The negative control

    func testWithTheWatcherOffARequestProducesNothingAtAll() async throws {
        // Run first, always: a probe that has not been shown to fail proves nothing. Every
        // other test in this file means something only because this one passes.
        let model = self.model(isOff: true)
        try submit(request())
        model.start()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(spawner.opened, [], "no terminal may be opened")
        XCTAssertNil(directory.result(id: "r"), "no result may be written")
        XCTAssertEqual(
            directory.pending().count, 1, "and the request is still sitting there, unclaimed")
    }

    func testTheModelKeepsTheBenchAdapterAlive() async throws {
        // A regression, and it cost the first live run. The spawner was `weak`, and the adapter
        // `RootView` builds inline is retained by nothing else — so it was gone before any
        // request arrived and every spawn answered "helm has no workbench to open a terminal
        // in". Attaching from a scope that then ends is exactly the composition helm uses.
        try mailbox("tmp-9999", pid: FakeSpawner.agentPid, sessionId: "s")
        let model = SpoolModel(
            directory: directory, mailRoot: mailRoot, isOff: false,
            shellDeadline: .seconds(5), claimDeadline: .seconds(3))
        weak var observed: FakeSpawner?
        do {
            let temporary = FakeSpawner()
            observed = temporary
            model.attach(spawner: temporary)
        }
        XCTAssertNotNil(observed, "the model must hold what it was attached to")

        try submit(request())
        model.start()
        _ = await awaitResult(is: .ready)
        XCTAssertEqual(observed?.opened.count, 1)
    }

    // MARK: - Refusals

    func testACommandOutsideTheAllowlistIsRefusedWithItsReason() async throws {
        let model = self.model()
        try submit(request(command: "sh"))
        model.start()
        let result = await awaitResult(is: .refused)
        XCTAssertEqual(spawner.opened, [], "nothing may be started")
        XCTAssertTrue(result?.reason?.contains("sh") == true)
    }

    func testAMalformedRequestIsAnsweredUnderItsFilename() async throws {
        // A refused request that writes nothing is indistinguishable from helm not running,
        // which is the silence this whole ladder exists to remove. With no readable `id`, the
        // filename is the only address the caller and helm agree on.
        let model = self.model()
        try submit("{ this is not json", named: "broken.json")
        model.start()
        let result = await awaitResult(id: "broken", is: .refused)
        XCTAssertTrue(result?.reason?.contains("JSON") == true)
    }

    // MARK: - Starting an agent

    func testARequestOpensATerminalAndTheLaunchLineGoesIntoItsPty() async throws {
        try mailbox("tmp-9999", pid: FakeSpawner.agentPid, sessionId: "session-9999")
        let model = self.model()
        try submit(request(prompt: "hello there"))
        model.start()

        let ready = await awaitResult(is: .ready)
        XCTAssertEqual(spawner.opened, [FileManager.default.temporaryDirectory.path])
        XCTAssertEqual(ready?.terminalId, spawner.terminal.uuidString)

        // The line went to *this* surface — not through the keyboard, not at whatever pane
        // held focus. And the prompt is read from a file, so it never touches word splitting.
        let line = try XCTUnwrap(spawner.sent.first?.line)
        XCTAssertTrue(line.hasPrefix("'claude'"))
        XCTAssertTrue(line.contains("\"$(cat '"))
        XCTAssertFalse(line.contains("hello there"))
        XCTAssertEqual(
            try String(
                contentsOf: directory.prompts.appendingPathComponent("r.txt"),
                encoding: .utf8), "hello there")
    }

    func testTheResultCarriesTheHandleReadOutOfTheMailbox() async throws {
        // `helm-4831` is deliberately NOT what `<cwd basename>-<last 4 of the session id>`
        // would produce for this cwd and session — a derivation would answer with something
        // else here, silently, which is the whole reason the handle is looked up.
        try mailbox("helm-4831", pid: FakeSpawner.agentPid, sessionId: "52256761-dd8f-4831")
        let model = self.model()
        try submit(request())
        model.start()

        let ready = await awaitResult(is: .ready)
        XCTAssertEqual(ready?.handle, "helm-4831")
        XCTAssertEqual(ready?.sessionId, "52256761-dd8f-4831")
        XCTAssertEqual(ready?.runtime, "claude")
        XCTAssertEqual(ready?.pid, FakeSpawner.agentPid)
    }

    func testTheAnswerIsImmediateAndThenBecomesAddressable() async throws {
        // The `handle`-timing decision, made visible: `started` lands within milliseconds so a
        // caller can tell "helm has this" from "helm is not running", and the handle arrives on
        // a second write once the agent's own SessionStart hook has claimed a mailbox.
        spawner.claimsOnSend = false
        let model = self.model(claimDeadline: .seconds(10))
        try submit(request())
        model.start()

        let started = await awaitResult(is: .started)
        XCTAssertNil(started?.handle, "there is no mailbox yet, and helm does not invent one")
        XCTAssertNotNil(started?.terminalId, "but the terminal is real and named")

        // The agent comes up late, exactly as a real one does.
        spawner.pids[spawner.terminal] = FakeSpawner.agentPid
        try mailbox("late-0001", pid: FakeSpawner.agentPid, sessionId: "late")
        let ready = await awaitResult(is: .ready)
        XCTAssertEqual(ready?.handle, "late-0001")
        XCTAssertGreaterThan(
            ready?.updatedAt ?? 0, started?.updatedAt ?? 0,
            "the caller can see the second write")
    }

    func testAnAgentThatNeverClaimsAMailboxStillGetsAnAnswer() async throws {
        // The cost of the two-write choice, and it is paid rather than hidden: a session that
        // never claims must still time out into a result, or the caller waits forever.
        spawner.claimsOnSend = false
        let model = self.model(claimDeadline: .milliseconds(600))
        try submit(request())
        model.start()

        let result = await awaitResult(is: .unclaimed)
        XCTAssertNil(result?.handle)
        XCTAssertTrue(result?.reason?.contains("cannot be addressed") == true)
        XCTAssertEqual(spawner.sent.count, 1, "the terminal is left alone, not torn down")
    }

    // MARK: - Exactly once

    func testTwoWatchersOverOneSpoolActOnARequestOnce() async throws {
        try mailbox("tmp-9999", pid: FakeSpawner.agentPid, sessionId: "s")
        let second = FakeSpawner()
        let other = SpoolModel(
            directory: directory, mailRoot: mailRoot, isOff: false,
            shellDeadline: .seconds(5), claimDeadline: .seconds(3))
        other.attach(spawner: second)

        let model = self.model()
        try submit(request())
        model.start()
        other.start()
        // And again, the way a backstop rescan would.
        model.drain()
        other.drain()

        _ = await awaitResult(is: .ready)
        XCTAssertEqual(
            spawner.opened.count + second.opened.count, 1,
            "two windows must not both open a terminal for one request")
    }

    func testARequestClaimedByAPreviousRunIsAnsweredRatherThanReRun() async throws {
        // The restart case. A claimed file is indistinguishable from one being worked on, so
        // re-running it is the double-open #54 forbids — it is answered instead.
        let stranded = try submit(request(id: "stranded"), named: "stranded.json")
        XCTAssertNotNil(directory.claim(stranded))

        let model = self.model()
        model.start()

        let result = await awaitResult(id: "stranded", is: .abandoned)
        XCTAssertTrue(result?.reason?.contains("NOT re-run") == true)
        XCTAssertEqual(spawner.opened, [], "nothing may be re-opened after a restart")
    }
}

/// A bench that is not there: it hands back pane ids and remembers what was written to them.
///
/// It models the two things the real one cannot be asked about in a test — that a pty takes a
/// moment to have a foreground process, and that the foreground moves off the login shell when
/// the launch line runs.
@MainActor
private final class FakeSpawner: SpoolSpawning {
    static let shellPid: pid_t = 91001
    static let agentPid: pid_t = 91002

    let terminal = UUID()
    var opened: [String] = []
    var sent: [(line: String, terminal: UUID)] = []
    var pids: [UUID: pid_t] = [:]
    var refusal: String?
    /// Whether the launch line brings an agent to the foreground straight away. `false` is a
    /// real agent that is still starting up.
    var claimsOnSend = true

    func openTerminal(cwd: String) -> Result<UUID, SpoolRefusal> {
        if let refusal { return .failure(SpoolRefusal(refusal)) }
        opened.append(cwd)
        pids[terminal] = Self.shellPid
        return .success(terminal)
    }

    func foregroundPid(of terminal: UUID) -> pid_t? { pids[terminal] }

    func send(_ line: String, to terminal: UUID) {
        sent.append((line, terminal))
        if claimsOnSend { pids[terminal] = Self.agentPid }
    }
}
