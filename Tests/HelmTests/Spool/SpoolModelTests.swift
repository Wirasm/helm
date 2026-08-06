import HelmWire
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
    private var registryRoot: URL!
    private var spawner: FakeSpawner!
    private var capturer: FakeCapturer!
    private var closer: FakeCloser!
    private var commander: FakeCommander!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-spool-model-\(UUID().uuidString)")
        directory = SpoolDirectory(root: base.appendingPathComponent("spool"))
        mailRoot = base.appendingPathComponent("mail")
        registryRoot = base.appendingPathComponent("sessions")
        try directory.prepare()
        try FileManager.default.createDirectory(at: mailRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: registryRoot, withIntermediateDirectories: true)
        spawner = FakeSpawner()
        capturer = FakeCapturer()
        closer = FakeCloser()
        commander = FakeCommander()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory.root.deletingLastPathComponent())
        directory = nil
        mailRoot = nil
        registryRoot = nil
        spawner = nil
        capturer = nil
        closer = nil
        commander = nil
    }

    // MARK: - Fixtures

    private func model(
        claimDeadline: Duration = .seconds(3), isOff: Bool = false
    ) -> SpoolModel {
        let model = SpoolModel(
            directory: directory, mailRoot: mailRoot, registryRoot: registryRoot, isOff: isOff,
            shellDeadline: .seconds(5), claimDeadline: claimDeadline)
        model.attach(spawner: spawner)
        model.attach(capturer: capturer)
        model.attach(closer: closer)
        model.attach(commander: commander)
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

    private func close(id: String = "bye", force: Bool = false) -> String {
        #"{"id":"\#(id)","kind":"close","terminal":"\#(closer.terminal.uuidString)","force":\#(force)}"#
    }

    private func command(id: String = "go", name: String = "splitRight") -> String {
        #"{"id":"\#(id)","kind":"command","command":"\#(name)"}"#
    }

    private func mailbox(_ handle: String, pid: pid_t, sessionId: String) throws {
        let dir = mailRoot.appendingPathComponent(handle)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try
            #"{"handle":"\#(handle)","runtime":"claude","pid":\#(pid),"sessionId":"\#(sessionId)","cwd":"/tmp"}"#
            .write(to: dir.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)
    }

    /// One row of Claude Code's own registry, `~/.claude/sessions/<pid>.json` — where the
    /// session named by a mailbox is running *now*.
    ///
    /// Seeded beside every mailbox because that is the real state of the world: an agent that
    /// has claimed a mailbox has also published its row. Since #247 it is what a spawn is
    /// resolved through, so a mailbox without one is an agent helm cannot yet name.
    private func registryRow(pid: pid_t, sessionId: String) throws {
        try #"{"pid":\#(pid),"sessionId":"\#(sessionId)","cwd":"/tmp","status":"busy"}"#
            .write(
                to: registryRoot.appendingPathComponent("\(pid).json"), atomically: true,
                encoding: .utf8)
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

    func testWithTheWatcherOffACaptureProducesNoPngAndNoResult() async throws {
        // The same negative control, for #174's half of the channel. A capture that "worked"
        // against a helm with the watcher switched off would mean the PNG came from somewhere
        // else — which is exactly the confusion a probe is supposed to rule out.
        let model = self.model(isOff: true)
        try submit(#"{"id":"shot","kind":"capture"}"#, named: "shot.json")
        model.start()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(capturer.captured, [], "nothing may be drawn")
        XCTAssertNil(directory.result(id: "shot"), "no result may be written")
        XCTAssertEqual(directory.pending().count, 1, "and the request is still sitting there")
    }

    func testTheModelKeepsTheBenchAdapterAlive() async throws {
        // A regression, and it cost the first live run. The spawner was `weak`, and the adapter
        // `RootView` builds inline is retained by nothing else — so it was gone before any
        // request arrived and every spawn answered "helm has no workbench to open a terminal
        // in". Attaching from a scope that then ends is exactly the composition helm uses.
        try mailbox("tmp-9999", pid: FakeSpawner.agentPid, sessionId: "s")
        try registryRow(pid: FakeSpawner.agentPid, sessionId: "s")
        let model = SpoolModel(
            directory: directory, mailRoot: mailRoot, registryRoot: registryRoot, isOff: false,
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
        try registryRow(pid: FakeSpawner.agentPid, sessionId: "session-9999")
        let model = self.model()
        try submit(request(prompt: "hello there"))
        model.start()

        let ready = await awaitResult(is: .ready)
        XCTAssertEqual(spawner.opened, [FileManager.default.temporaryDirectory.path])
        XCTAssertEqual(ready?.terminalId?.uuidString, spawner.terminal.uuidString)

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
        try registryRow(pid: FakeSpawner.agentPid, sessionId: "52256761-dd8f-4831")
        let model = self.model()
        try submit(request())
        model.start()

        let ready = await awaitResult(is: .ready)
        XCTAssertEqual(ready?.handle?.value, "helm-4831")
        XCTAssertEqual(ready?.sessionId, "52256761-dd8f-4831")
        XCTAssertEqual(ready?.runtime, "claude")
        XCTAssertEqual(ready?.pid, FakeSpawner.agentPid)
    }

    /// #247, end to end through the consumer that hurts most: **a spawn answered with another
    /// agent's handle**. The caller's very next move is to send mail to what it was told, so a
    /// wrong handle here is a message written into a mailbox nobody reads, with no error.
    ///
    /// `stale-0000` recorded this pid at its own `SessionStart` and never rewrote it; that
    /// process is gone and macOS handed the number back. #236 is why the row is still here to
    /// be hit — before it, a stale-pid owner was reaped and could not be matched at all.
    func testASpawnIsAnsweredWithTheAgentTheRegistryNamesNotTheStaleRowAtThatPid() async throws {
        try mailbox("stale-0000", pid: FakeSpawner.agentPid, sessionId: "a-session-that-ended")
        try mailbox("fresh-1111", pid: 40404, sessionId: "the-live-session")
        try registryRow(pid: FakeSpawner.agentPid, sessionId: "the-live-session")

        let model = self.model()
        try submit(request())
        model.start()

        let ready = await awaitResult(is: .ready)
        XCTAssertEqual(
            ready?.handle?.value, "fresh-1111",
            "the pid was recycled — this spawn was answered with a dead agent's address")
        XCTAssertEqual(ready?.sessionId, "the-live-session")
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
        try registryRow(pid: FakeSpawner.agentPid, sessionId: "late")
        let ready = await awaitResult(is: .ready)
        XCTAssertEqual(ready?.handle?.value, "late-0001")
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
        try registryRow(pid: FakeSpawner.agentPid, sessionId: "s")
        let second = FakeSpawner()
        let other = SpoolModel(
            directory: directory, mailRoot: mailRoot, registryRoot: registryRoot, isOff: false,
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

    // MARK: - Capture (#174)

    func testACaptureAnswersWithThePngAndWhatIsInIt() async throws {
        let model = self.model()
        try submit(#"{"id":"shot","kind":"capture"}"#, named: "shot.json")
        model.start()

        let result = await awaitResult(id: "shot", is: .captured)
        // The default destination is the spool's own `captures/`, resolved by the policy so
        // nothing downstream re-derives it.
        XCTAssertEqual(
            capturer.captured, [directory.captures.appendingPathComponent("shot.png").path])
        XCTAssertEqual(result?.capture?.path, capturer.captured.first)
        XCTAssertEqual(spawner.opened, [], "a capture starts no agent")
    }

    func testTheResultSaysTerminalContentIsExcludedRatherThanLeavingItToBeAssumed() async throws {
        // The acceptance criterion #174 spends most of its words on: *"a PNG with a blank
        // terminal that does not announce itself is worse than no PNG"*. A caller must be able
        // to read the answer rather than infer it from a picture.
        capturer.terminalSurfaces = 3
        let model = self.model()
        try submit(#"{"id":"shot","kind":"capture"}"#, named: "shot.json")
        model.start()

        let result = await awaitResult(id: "shot", is: .captured)
        XCTAssertEqual(result?.capture?.terminalContent, .excluded)
        XCTAssertEqual(result?.capture?.terminalSurfaces, 3)

        // And a window with no terminal in it says so differently: nothing is missing there.
        capturer.terminalSurfaces = 0
        try submit(#"{"id":"empty","kind":"capture"}"#, named: "empty.json")
        model.drain()
        let bench = await awaitResult(id: "empty", is: .captured)
        XCTAssertEqual(bench?.capture?.terminalContent, .absent)
    }

    func testACaptureThatCannotBeDrawnFailsWithItsReasonRatherThanSilently() async throws {
        // The negative case #174 asks for by name: a window that is not there is refused
        // visibly. Every other spool request has this rule and a capture is not an exception.
        capturer.refusal = "helm has no visible window to draw (0 window(s) exist)"
        let model = self.model()
        try submit(#"{"id":"shot","kind":"capture"}"#, named: "shot.json")
        model.start()

        let result = await awaitResult(id: "shot", is: .failed)
        XCTAssertEqual(result?.reason?.contains("no visible window") == true, true)
        XCTAssertNil(result?.capture, "a failure names no PNG, because there is none")
    }

    func testACaptureIsActedOnAtMostOnce() async throws {
        // Exactly-once is a property of the channel, not of the spawn: two windows draining one
        // spool must not write the same PNG twice, and a backstop rescan must not either.
        let second = FakeCapturer()
        let other = SpoolModel(
            directory: directory, mailRoot: mailRoot, registryRoot: registryRoot, isOff: false,
            shellDeadline: .seconds(5), claimDeadline: .seconds(3))
        other.attach(spawner: FakeSpawner())
        other.attach(capturer: second)

        let model = self.model()
        try submit(#"{"id":"shot","kind":"capture"}"#, named: "shot.json")
        model.start()
        other.start()
        model.drain()
        other.drain()

        _ = await awaitResult(id: "shot", is: .captured)
        XCTAssertEqual(capturer.captured.count + second.captured.count, 1)
    }

    func testAnUnknownKindIsRefusedByNameRatherThanTreatedAsASpawn() async throws {
        let model = self.model()
        try submit(#"{"id":"odd","kind":"teleport"}"#, named: "odd.json")
        model.start()

        let result = await awaitResult(id: "odd", is: .refused)
        XCTAssertEqual(result?.reason?.contains("teleport") == true, true)
        XCTAssertEqual(spawner.opened, [], "and nothing is started on the strength of a guess")
    }

    // MARK: - Close (#176)

    func testWithTheWatcherOffACloseTouchesNothing() async throws {
        // The negative control, for the destructive kind. A pane that vanished while the
        // watcher was off would have to have been closed by something else.
        let model = self.model(isOff: true)
        try submit(close(), named: "bye.json")
        model.start()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(closer.closed, [], "no pane may be closed")
        XCTAssertNil(directory.result(id: "bye"), "no result may be written")
        XCTAssertEqual(directory.pending().count, 1, "and the request is still sitting there")
    }

    func testAnIdlePaneIsClosedAndTheResultNamesItAndWhatWasInIt() async throws {
        let model = self.model()
        try submit(close(), named: "bye.json")
        model.start()

        let result = await awaitResult(id: "bye", is: .closed)
        XCTAssertEqual(closer.closed, [closer.terminal])
        XCTAssertEqual(result?.terminalId?.uuidString, closer.terminal.uuidString)
        // What was in the pane when it went — the login shell here, because it was idle.
        XCTAssertEqual(result?.pid, FakeCloser.shellPid)
        XCTAssertEqual(spawner.opened, [], "a close starts nothing")
    }

    func testAPaneTheOperatorIsInIsRefusedAndStaysOnTheBench() async throws {
        // The acceptance criterion in as many words: *a pane the operator is focused on is
        // never closed out from under them*. And it is a REFUSAL, with a reason — a teardown
        // that silently did nothing is indistinguishable from helm not running.
        closer.state = SpoolPaneState(
            holdsTerminal: true, holdsKeyboard: true, foreground: FakeCloser.shellPid,
            foregroundParent: FakeCloser.loginPid, sessionLeader: FakeCloser.loginPid)
        let model = self.model()
        try submit(close(force: true), named: "bye.json")
        model.start()

        let result = await awaitResult(id: "bye", is: .refused)
        XCTAssertEqual(result?.reason?.contains("operator") == true, true)
        XCTAssertEqual(closer.closed, [], "the pane is still there")
    }

    func testALivePaneIsRefusedUntilTheRequestSaysForce() async throws {
        closer.state = SpoolPaneState(
            holdsTerminal: true, holdsKeyboard: false, foreground: FakeCloser.agentPid,
            foregroundParent: FakeCloser.shellPid, sessionLeader: FakeCloser.loginPid)
        let model = self.model()
        try submit(close(), named: "bye.json")
        model.start()

        let refused = await awaitResult(id: "bye", is: .refused)
        XCTAssertEqual(refused?.reason?.contains("force") == true, true)
        XCTAssertEqual(closer.closed, [])

        // Said explicitly, the same pane goes — and the result names the pid that went with it.
        try submit(close(id: "bye2", force: true), named: "bye2.json")
        model.drain()
        let closed = await awaitResult(id: "bye2", is: .closed)
        XCTAssertEqual(closer.closed, [closer.terminal])
        XCTAssertEqual(closed?.pid, FakeCloser.agentPid)
    }

    func testAPaneHelmDoesNotHaveIsRefusedRatherThanIgnored() async throws {
        closer.state = nil
        let model = self.model()
        try submit(close(), named: "bye.json")
        model.start()

        let result = await awaitResult(id: "bye", is: .refused)
        XCTAssertEqual(result?.reason?.contains(closer.terminal.uuidString) == true, true)
    }

    func testABenchThatWillNotLetGoIsReportedRatherThanCalledAClose() async throws {
        // `Workbench.canClose` refuses the bench's last pane. Answering `closed` about a pane
        // still sitting there would be a lie the caller has no way to check.
        closer.refuses = true
        let model = self.model()
        try submit(close(), named: "bye.json")
        model.start()

        let result = await awaitResult(id: "bye", is: .refused)
        XCTAssertEqual(result?.reason?.contains("last pane") == true, true)
    }

    func testACloseWithNoBenchAttachedIsAHelmDefectAndSaysSo() async throws {
        // `failed`, not `refused`: there is nothing the caller can do about it, and the two
        // are different exit codes on the way out.
        let model = SpoolModel(
            directory: directory, mailRoot: mailRoot, registryRoot: registryRoot, isOff: false,
            shellDeadline: .seconds(5), claimDeadline: .seconds(3))
        try submit(close(), named: "bye.json")
        model.start()

        let result = await awaitResult(id: "bye", is: .failed)
        XCTAssertEqual(result?.reason?.contains("helm defect") == true, true)
    }

    func testACloseIsActedOnAtMostOnce() async throws {
        // Exactly-once matters most for the destructive kind: two windows draining one spool
        // must not both try to tear the same pane down.
        let second = FakeCloser()
        second.terminal = closer.terminal
        let other = SpoolModel(
            directory: directory, mailRoot: mailRoot, registryRoot: registryRoot, isOff: false,
            shellDeadline: .seconds(5), claimDeadline: .seconds(3))
        other.attach(closer: second)

        let model = self.model()
        try submit(close(), named: "bye.json")
        model.start()
        other.start()
        model.drain()
        other.drain()

        _ = await awaitResult(id: "bye", is: .closed)
        XCTAssertEqual(closer.closed.count + second.closed.count, 1)
    }

    // MARK: - Command (#269)

    func testWithTheWatcherOffACommandTouchesNothing() async throws {
        // The negative control, per kind: it is what gives every other claim in this section
        // its meaning.
        let model = self.model(isOff: true)
        try submit(command(), named: "go.json")
        model.start()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(commander.ran, [], "no command may run")
        XCTAssertNil(directory.result(id: "go"), "no result may be written")
        XCTAssertEqual(directory.pending().count, 1, "and the request is still sitting there")
    }

    func testAnAllowedCommandRunsAndTheResultSaysWhatItDid() async throws {
        let model = self.model()
        try submit(command(name: "splitRight"), named: "go.json")
        model.start()

        let result = await awaitResult(id: "go", is: .ran)
        XCTAssertEqual(commander.ran, [.splitRight], "the command reached the bench")
        XCTAssertEqual(result?.command?.command, .splitRight, "…and the result names it")
        // The whole point of the report: the caller does not have to re-read snapshot.json
        // and race it to learn what its own request produced.
        XCTAssertEqual(result?.command?.paneCreated?.uuidString, commander.created.uuidString)
        XCTAssertEqual(
            result?.terminalId?.uuidString, commander.created.uuidString,
            "and it is copied to terminalId, so `helm-close <terminalId>` needs no lookup")
        XCTAssertEqual(
            result?.command?.focusedPaneBefore, result?.command?.focusedPaneAfter,
            "the focus rule, reported as two readings rather than asserted in a header")
        XCTAssertEqual(spawner.opened, [], "a command starts no agent")
    }

    func testACommandTheOperatorsFocusRuleForbidsIsRefusedWithItsReason() async throws {
        let model = self.model()
        try submit(command(name: "moveFocus"), named: "go.json")
        model.start()

        let result = await awaitResult(id: "go", is: .refused)
        XCTAssertTrue(
            result?.reason?.contains("moveFocus") == true,
            "the refusal names the command; got \(String(describing: result?.reason))")
        XCTAssertEqual(commander.ran, [], "and nothing reached the bench")
    }

    func testACommandNameHelmDoesNotHaveIsARefusalOfItsOwn() async throws {
        // Told apart from the refusal above on purpose: one is a typo the caller can fix, the
        // other is a standing decision it cannot.
        let model = self.model()
        try submit(command(name: "splitSideways"), named: "go.json")
        model.start()

        let result = await awaitResult(id: "go", is: .refused)
        XCTAssertTrue(result?.reason?.contains("is not a helm command") == true)
        XCTAssertEqual(commander.ran, [])
    }

    func testACommandWithNoBenchAttachedIsAHelmDefectAndSaysSo() async throws {
        // `failed`, not `refused` — the same distinction the close path draws.
        let model = SpoolModel(
            directory: directory, mailRoot: mailRoot, registryRoot: registryRoot, isOff: false,
            shellDeadline: .seconds(5), claimDeadline: .seconds(3))
        try submit(command(), named: "go.json")
        model.start()

        let result = await awaitResult(id: "go", is: .failed)
        XCTAssertEqual(result?.reason?.contains("helm defect") == true, true)
    }

    func testACommanderThatCannotActFailsWithItsReasonRatherThanSilently() async throws {
        commander.refusal = "helm has no workspace open"
        let model = self.model()
        try submit(command(), named: "go.json")
        model.start()

        let result = await awaitResult(id: "go", is: .failed)
        XCTAssertEqual(result?.reason, "helm has no workspace open")
    }

    func testACommandIsActedOnAtMostOnce() async throws {
        // Two windows draining one spool must not both split the bench.
        let second = FakeCommander()
        let other = SpoolModel(
            directory: directory, mailRoot: mailRoot, registryRoot: registryRoot, isOff: false,
            shellDeadline: .seconds(5), claimDeadline: .seconds(3))
        other.attach(commander: second)

        let model = self.model()
        try submit(command(), named: "go.json")
        model.start()
        other.start()
        model.drain()
        other.drain()

        _ = await awaitResult(id: "go", is: .ran)
        XCTAssertEqual(commander.ran.count + second.ran.count, 1)
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

/// A bench that is not there, from the teardown side: it reports whatever state the test wants
/// one pane to be in, and remembers what it was asked to close.
///
/// The pane state is a *value*, so every rule #176 argues for is exercised here without a
/// bench, a surface, a pty or a `getsid` — which is exactly the split `SpoolClosing` exists to
/// make.
@MainActor
private final class FakeCloser: SpoolClosing {
    /// The pty layout every helm pane really has: `login` is the session leader and forks
    /// the login shell as its only child.
    static let loginPid: pid_t = 92000
    static let shellPid: pid_t = 92001
    static let agentPid: pid_t = 92002

    var terminal = UUID()
    /// An idle terminal nobody is looking at, unless a test says otherwise.
    var state: SpoolPaneState? = SpoolPaneState(
        holdsTerminal: true, holdsKeyboard: false, foreground: shellPid,
        foregroundParent: loginPid, sessionLeader: loginPid)
    /// The bench refusing to let go — `Workbench.canClose` and its last pane.
    var refuses = false
    var closed: [UUID] = []

    func pane(_ id: UUID) -> SpoolPaneState? { id == terminal ? state : nil }

    func close(_ id: UUID) -> Bool {
        guard id == terminal, !refuses else { return false }
        closed.append(id)
        return true
    }
}

/// A bench that is not there, for the driving kind (#269). It records which commands reached it
/// and reports a bench that grew a pane and did not move the keyboard — which is what the real
/// `WorkbenchSpoolCommander` promises and what `SpoolCommandPolicy` argues for.
///
/// Whether a command may be sent at all never reaches here: `SpoolPolicy.accept` has already
/// refused everything the policy refuses, which is the seam that keeps that decision testable
/// without a bench in the first place.
@MainActor
private final class FakeCommander: SpoolCommanding {
    /// The pane a split or a new terminal produced, so a test can match it against the
    /// result's `paneCreated` and `terminalId`.
    let created = UUID()
    /// Where the keyboard was, and stays. One value on both sides of the report is the fake's
    /// way of modelling the promise; the real one measures it.
    let focused = UUID()
    var ran: [HelmCommandName] = []
    /// helm accepting a command it then cannot carry out — no workspace open, say.
    var refusal: String?

    func run(_ command: HelmCommandName) -> Result<CommandReport, SpoolRefusal> {
        if let refusal { return .failure(SpoolRefusal(refusal)) }
        ran.append(command)
        return .success(
            CommandReport(
                command: command, paneCreated: TerminalID(created),
                focusedPaneBefore: TerminalID(focused), focusedPaneAfter: TerminalID(focused),
                columns: 2, panes: 2))
    }
}

/// A window that is not there. It records where it was asked to draw and reports whatever the
/// test wants the view tree to have contained — which is how the `absent` / `excluded` answer
/// is exercised without a display, a window server or a Metal device.
@MainActor
private final class FakeCapturer: SpoolCapturing {
    var captured: [String] = []
    var windows: [String?] = []
    var terminalSurfaces = 0
    var refusal: String?

    func capture(to path: String, window: String?) -> Result<CaptureReport, SpoolRefusal> {
        if let refusal { return .failure(SpoolRefusal(refusal)) }
        captured.append(path)
        windows.append(window)
        return .success(
            CaptureReport(
                path: path, pixelWidth: 2560, pixelHeight: 1600, scale: 2, window: "helm",
                terminalContent: WindowCapture.content(
                    of: terminalSurfaces, missing: terminalSurfaces),
                terminalSurfaces: terminalSurfaces,
                terminalSurfacesExcluded: terminalSurfaces))
    }
}
