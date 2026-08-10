import Foundation
import HelmWire
import XCTest

/// Proves the standalone spool scripts and `HelmWire` still agree on the wire format — the
/// detectable half of the duplication `AGENTS.md` argues is honest (#221).
///
/// **Why the duplication exists at all.** `tools/helm-spool.swift`, `helm-close.swift`,
/// `helm-capture.swift`, `helm-command.swift` and `helm-select.swift` cannot `import HelmWire`: a single-file
/// `swift tools/…swift` script resolves no `Package.swift` and runs from any cwd, which is the
/// whole reason the spool is a script rather than an SPM target (`AGENTS.md`'s "Why the spool is
/// a script, and must stay one" has the measurements). So the request JSON, the result JSON and
/// the spool's own
/// directory-resolution rules are each spelled out twice — once here as `HelmWire` types and
/// functions, once by hand in each script. A duplicate is honest only when a runtime boundary
/// makes sharing impossible — this is that boundary — but honest still means it has to be
/// *watched*, not merely excused.
///
/// **This file covers three of the spool's four boundaries, and says which one it does not:**
///
/// 1. **The request direction** (script → helm): a script writes `<id>.json`, helm's
///    `SpoolDirectory.request(at:)` decodes it. Covered by the five `testHelm*WritesWhat
///    *RequestDecodes` tests below, unchanged from #221's first pass but for #269's fourth kind
///    and #284's fifth.
/// 2. **The result direction** (helm → script): helm writes `results/<id>.json`, the script
///    reads `json["status"] as? String` and switches on it by hand — one `switch status` per
///    script, none of which
///    decode through `SpoolResult`. Covered by `testHelm*ExitCodeAndStderrForEveryResultStatus`
///    below, over **every** `SpoolResult.Status` case for every script — `Status: CaseIterable`
///    plus an
///    exhaustive switch in `expectation(for:)` is what makes forgetting a script for a new
///    case a compile error in this file rather than a silent gap. `testHelm*PrintsHandleAnd
///    TerminalIdAsBareStringsOnceReady` (#229) covers the same direction from a different
///    angle: not "does the script exit right", but "are `handle` and `terminalId` still bare
///    strings once they cross into `Handle`/`TerminalID`" — the property those two newtypes
///    exist to hold, and the one an exit-code assertion cannot see even accidentally, since
///    neither script's exit code depends on either field's shape.
///    `testHelmCloseOnACanvasSaysThePaneIsGoneWithoutInventingAPidThatDied` (#284) is a third
///    angle on the same direction: an **absent optional**. `pid` was present on every `closed`
///    result until a canvas pane could be closed, and the script reads it by hand — so the
///    failure to guard against is a wrong sentence on stderr at exit 0, which neither the
///    status sweep nor a bare-string assertion can see.
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
///
/// **That cost is what every deadline here is really waiting on, and it is not what any test
/// here has an opinion about** — see `scriptBudget` below for why the number is 60s rather
/// than the 10s that twice reported a busy machine as a drifted wire format (#291).
final class SpoolWireConformanceTests: XCTestCase {
    private var spoolDir: URL!
    private var runningProcesses: [Process] = []

    override func setUpWithError() throws {
        spoolDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-spool-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
        try SpoolDirectory(root: spoolDir).prepare()
    }

    /// **How long a `swift tools/<script>` invocation is given, and what that number is not.**
    ///
    /// It is a **hang guard**, not a performance bar. Every wait in this suite is really
    /// waiting on two things at once — `swift <file>` *compiling* the script, and then the
    /// script doing its job — and only the second is what any test here has an opinion about.
    ///
    /// It was 10s, and 10s is inside the noise on the compile half. Measured on this machine:
    /// one `swift tools/helm-capture.swift` is **0.32s** with a warm module cache, even at
    /// load 61 on 11 cores. On a cold GitHub runner it is the first compile of anything, with
    /// no cache at all — and run 31156875717 is that costing more than 10s and taking the
    /// gate down on a branch whose diff touches no file this test reads (#291).
    ///
    /// 60s is 6× the worst honest cold compile and still fails a genuinely hung script inside
    /// a minute. **Raise it rather than trimming it if it fires again** — a red here is
    /// supposed to mean *the spool wire drifted*, and that is the most alarming thing this
    /// suite can say. It must never be the sentence a busy machine produces.
    private static let scriptBudget: TimeInterval = 60

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

    /// **The `terminal` key is the assertion, and #284 deliberately left it alone.** Widening a
    /// close to reach a canvas pane changed no field here: `Pane.id` is one uuid namespace, so a
    /// canvas close is byte-identical to a terminal close (`CloseRequest`'s header argues why it
    /// grew no discriminator). This test is therefore also the control for that claim — a script
    /// that had started writing `"pane"` instead would fail on the decode, not on the value.
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

    func testHelmCommandWritesWhatCommandRequestDecodes() throws {
        let id = "conformance-command"
        try run("helm-command.swift", ["splitRight", "--id", id])

        guard case .command(let command) = try decodedRequest(id: id) else {
            return XCTFail(
                "helm-command.swift wrote a request HelmWire did not decode as a command")
        }
        XCTAssertEqual(command.command, "splitRight")
    }

    /// **`pane` is the assertion here, where the close test's is `terminal`** — the two requests
    /// carry the same value under different keys, deliberately (#284): a close keeps the name
    /// every helm since #176 decodes, and a select has no wire history to keep faith with. A
    /// script that had copied the close's key would fail on the decode, not on the value.
    func testHelmSelectWritesWhatSelectRequestDecodes() throws {
        let id = "conformance-select"
        let pane = UUID()
        try run("helm-select.swift", [pane.uuidString, "--id", id])

        guard case .select(let select) = try decodedRequest(id: id) else {
            return XCTFail("helm-select.swift wrote a request HelmWire did not decode as a select")
        }
        XCTAssertEqual(select.pane, pane.uuidString)
    }

    /// **The whole payload, because a name is the first addressed request that carries more than
    /// an id** (#313). `rename` in particular has to arrive as a real boolean the decoder reads:
    /// a script that wrote it as the string `"false"` would decode as `false` too (via
    /// `decodeIfPresent(Bool.self)` failing into the default) and look correct, while
    /// `--rename` — the flag that says the operator asked — silently did nothing.
    func testHelmNameWritesWhatNameRequestDecodes() throws {
        let id = "conformance-name"
        let pane = UUID()
        try run("helm-name.swift", [pane.uuidString, "review the diff", "--id", id])

        guard case .name(let name) = try decodedRequest(id: id) else {
            return XCTFail("helm-name.swift wrote a request HelmWire did not decode as a name")
        }
        XCTAssertEqual(name.pane, pane.uuidString)
        XCTAssertEqual(name.name, "review the diff")
        XCTAssertFalse(name.rename, "the safe default has to survive the wire, not just the type")
    }

    func testHelmNameCarriesTheRenameFlagAsABooleanTheDecoderReads() throws {
        let id = "conformance-name-rename"
        let pane = UUID()
        try run("helm-name.swift", [pane.uuidString, "the plan", "--rename", "--id", id])

        guard case .name(let name) = try decodedRequest(id: id) else {
            return XCTFail("helm-name.swift wrote a request HelmWire did not decode as a name")
        }
        XCTAssertTrue(
            name.rename,
            "--rename is the caller saying the operator asked; if it does not survive the wire "
                + "the flag is decoration and every rename is refused")
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
        case .ran: return ResultExpectation(exitCode: 4, stderrContains: "unknown status")
        case .selected: return ResultExpectation(exitCode: 4, stderrContains: "unknown status")
        case .named: return ResultExpectation(exitCode: 4, stderrContains: "unknown status")
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
        case .ran:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status ran")
        case .selected:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status selected")
        case .named:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status named")
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
        case .ran:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status ran")
        case .selected:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status selected")
        case .named:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status named")
        case .unclaimed:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status unclaimed")
        case .refused: return ResultExpectation(exitCode: 3, stderrContains: "not an agent")
        case .failed: return ResultExpectation(exitCode: 4, stderrContains: "could not act")
        case .abandoned: return ResultExpectation(exitCode: 6, stderrContains: "stopped mid-flight")
        }
    }

    /// helm-command.swift's own `Exit` enum — ok=0, refused=3, failed=4, abandoned=6 (#269).
    /// Same shape as the two above: a command is one write, so everything but `ran` falls to
    /// `default:`.
    private func helmCommandExpectation(for status: SpoolResult.Status) -> ResultExpectation {
        switch status {
        case .started:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status started")
        case .ready:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status ready")
        case .captured:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status captured")
        case .closed:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status closed")
        case .ran:
            return ResultExpectation(exitCode: 0, stderrContains: "splitRight ran")
        case .selected:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status selected")
        case .named:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status named")
        case .unclaimed:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status unclaimed")
        case .refused: return ResultExpectation(exitCode: 3, stderrContains: "not an agent")
        case .failed: return ResultExpectation(exitCode: 4, stderrContains: "could not act")
        case .abandoned: return ResultExpectation(exitCode: 6, stderrContains: "stopped mid-flight")
        }
    }

    /// helm-select.swift's own `Exit` enum — ok=0, refused=3, failed=4, abandoned=6 (#284).
    /// Same shape as the three above: a select is one write, so everything but `selected` falls
    /// to `default:`.
    private func helmSelectExpectation(for status: SpoolResult.Status) -> ResultExpectation {
        switch status {
        case .started:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status started")
        case .ready:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status ready")
        case .captured:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status captured")
        case .closed:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status closed")
        case .ran:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status ran")
        case .selected:
            return ResultExpectation(exitCode: 0, stderrContains: "is visible")
        case .named:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status named")
        case .unclaimed:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status unclaimed")
        case .refused: return ResultExpectation(exitCode: 3, stderrContains: "not an agent")
        case .failed: return ResultExpectation(exitCode: 4, stderrContains: "could not act")
        case .abandoned: return ResultExpectation(exitCode: 6, stderrContains: "stopped mid-flight")
        }
    }

    /// helm-name.swift's own `Exit` enum — ok=0, refused=3, failed=4, abandoned=6 (#313).
    /// Same shape as the four above: a name is one write, so everything but `named` falls to
    /// `default:`.
    private func helmNameExpectation(for status: SpoolResult.Status) -> ResultExpectation {
        switch status {
        case .started:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status started")
        case .ready:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status ready")
        case .captured:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status captured")
        case .closed:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status closed")
        case .ran:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status ran")
        case .selected:
            return ResultExpectation(exitCode: 4, stderrContains: "unexpected status selected")
        case .named:
            return ResultExpectation(exitCode: 0, stderrContains: "is now")
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
    private func result(id: String, status: SpoolResult.Status, terminal: UUID) -> SpoolResult {
        switch status {
        case .started:
            return SpoolResult(id: id, status: .started, terminalId: TerminalID(terminal))
        case .ready:
            return SpoolResult(
                id: id, status: .ready, terminalId: TerminalID(terminal), pid: 4242,
                sessionId: "sess-1", handle: Handle(validating: "helm-4242"), runtime: "claude")
        case .captured:
            return SpoolResult(
                id: id, status: .captured,
                capture: CaptureReport(
                    path: "/tmp/conformance-result-capture.png", pixelWidth: 800,
                    pixelHeight: 600, scale: 2, window: "helm", terminalContent: .included,
                    terminalSurfaces: 1, terminalSurfacesExcluded: 0))
        case .closed:
            return SpoolResult(id: id, status: .closed, terminalId: TerminalID(terminal), pid: 4242)
        case .ran:
            return SpoolResult(
                id: id, status: .ran, terminalId: TerminalID(terminal),
                command: CommandReport(
                    command: .splitRight, paneCreated: TerminalID(terminal),
                    focusedPaneBefore: TerminalID(terminal), focusedPaneAfter: TerminalID(terminal),
                    columns: 2, panes: 2))
        case .selected:
            return SpoolResult(
                id: id, status: .selected, terminalId: TerminalID(terminal),
                select: SelectReport(
                    pane: TerminalID(terminal), isVisible: true,
                    focusedPaneBefore: TerminalID(terminal),
                    focusedPaneAfter: TerminalID(terminal)))
        case .named:
            return SpoolResult(
                id: id, status: .named, terminalId: TerminalID(terminal),
                name: NameReport(
                    pane: TerminalID(terminal), previousName: "claude · helm",
                    name: "review the diff"))
        case .unclaimed:
            return SpoolResult(
                id: id, status: .unclaimed, terminalId: TerminalID(terminal), pid: 4242,
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
            SpoolDirectory(root: spoolDir).write(
                result(id: id, status: status, terminal: UUID()))

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
        SpoolDirectory(root: spoolDir).write(
            result(id: id, status: .started, terminal: UUID()))
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
                result(id: id, status: status, terminal: terminal))

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
            SpoolDirectory(root: spoolDir).write(
                result(id: id, status: status, terminal: UUID()))

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

    func testHelmCommandExitCodeAndStderrForEveryResultStatus() throws {
        for status in SpoolResult.Status.allCases {
            let id = "command-result-\(status.rawValue)"
            SpoolDirectory(root: spoolDir).write(
                result(id: id, status: status, terminal: UUID()))

            let (exitCode, stderr) = try runAndCapture(
                "helm-command.swift", ["splitRight", "--id", id])

            let expectation = helmCommandExpectation(for: status)
            XCTAssertEqual(
                exitCode, expectation.exitCode,
                "helm-command.swift on status \(status.rawValue): exit \(exitCode), stderr: \(stderr)"
            )
            XCTAssertTrue(
                stderr.contains(expectation.stderrContains),
                "helm-command.swift on status \(status.rawValue): expected stderr to contain "
                    + "\"\(expectation.stderrContains)\", got \"\(stderr)\"")
        }
    }

    func testHelmSelectExitCodeAndStderrForEveryResultStatus() throws {
        for status in SpoolResult.Status.allCases {
            let pane = UUID()
            let id = "select-result-\(status.rawValue)"
            SpoolDirectory(root: spoolDir).write(
                result(id: id, status: status, terminal: pane))

            let (exitCode, stderr) = try runAndCapture(
                "helm-select.swift", [pane.uuidString, "--id", id])

            let expectation = helmSelectExpectation(for: status)
            XCTAssertEqual(
                exitCode, expectation.exitCode,
                "helm-select.swift on status \(status.rawValue): exit \(exitCode), stderr: \(stderr)"
            )
            XCTAssertTrue(
                stderr.contains(expectation.stderrContains),
                "helm-select.swift on status \(status.rawValue): expected stderr to contain "
                    + "\"\(expectation.stderrContains)\", got \"\(stderr)\"")
        }
    }

    func testHelmNameExitCodeAndStderrForEveryResultStatus() throws {
        for status in SpoolResult.Status.allCases {
            let pane = UUID()
            let id = "name-result-\(status.rawValue)"
            SpoolDirectory(root: spoolDir).write(
                result(id: id, status: status, terminal: pane))

            let (exitCode, stderr) = try runAndCapture(
                "helm-name.swift", [pane.uuidString, "review the diff", "--id", id])

            let expectation = helmNameExpectation(for: status)
            XCTAssertEqual(
                exitCode, expectation.exitCode,
                "helm-name.swift on status \(status.rawValue): exit \(exitCode), stderr: \(stderr)"
            )
            XCTAssertTrue(
                stderr.contains(expectation.stderrContains),
                "helm-name.swift on status \(status.rawValue): expected stderr to contain "
                    + "\"\(expectation.stderrContains)\", got \"\(stderr)\"")
        }
    }

    // MARK: - 2c. helm-command's own restated allowlist (#269)

    /// **The one thing `helm-command.swift` restates beyond the JSON shape, watched the same
    /// way everything else across this boundary is.** The script carries the four allowed names
    /// so that `--list` can answer with no helm running — which is exactly when an agent wants
    /// to ask — and a single-file script cannot `import HelmWire` to get them. So this runs the
    /// real script and compares its real output against the real `SpoolCommandPolicy`.
    ///
    /// It needs no spool at all: `--list` exits before the directory is resolved, which is
    /// itself part of the promise.
    func testHelmCommandListsExactlyTheCommandsSpoolCommandPolicyAllows() throws {
        let (exitCode, stdout, stderr) = try runAndCaptureBoth("helm-command.swift", ["--list"])
        XCTAssertEqual(exitCode, 0, "--list must succeed with no helm running; stderr: \(stderr)")

        let listed = stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(
            listed, SpoolCommandPolicy.allowed.map(\.rawValue),
            "helm-command.swift's hand-copied allowlist has drifted from SpoolCommandPolicy — "
                + "the script cannot import HelmWire (see this file's header), so the copy is "
                + "honest only while this test holds it")
    }

    // MARK: - 2b. handle and terminalId are bare strings, not objects (#229)

    /// **The property #229 introduced `Handle` and `TerminalID` to hold, proved the way the
    /// issue asks for: by inspecting the actual JSON, not by a Swift round trip.** A round trip
    /// through `Codable` cannot fail regardless of the container either type uses — decoding
    /// and re-encoding a `Handle`/`TerminalID` would agree with itself even if `encode(to:)`
    /// were changed to a keyed container tomorrow, because the decoder would just as happily
    /// read a nested `{"value":"…"}` back. What cannot lie is the actual bytes on disk, read
    /// with `JSONSerialization` — the same untyped decoder `helm-spool.swift` and
    /// `helm-close.swift` use, because neither can `import HelmWire` (this file's own header
    /// explains why). So each test here writes a real `SpoolResult` through real `HelmWire`
    /// code, runs the real script against it, and inspects what the *script itself* printed
    /// back to its own stdout (`helm-spool.swift:186`, `helm-close.swift:153` — both print the
    /// result file verbatim before switching on `status`), asserting `is String` on the two
    /// fields directly rather than comparing against a literal.
    ///
    /// **Watched red, then reverted, per `AGENTS.md`'s "watch a test fail before you trust it
    /// passing".** Changing `TerminalID.encode(to:)` to `try container.encode(["uuid": uuid
    /// .uuidString])` turns `testHelmSpoolPrintsHandleAndTerminalIdAsBareStringsOnceReady` red
    /// on the `terminalId` assertion, naming the offending value as a dictionary rather than a
    /// string. Restoring the single-value container turns it green again. See this PR's
    /// description for the transcript.
    func testHelmSpoolPrintsHandleAndTerminalIdAsBareStringsOnceReady() throws {
        let id = "wire-shape-ready"
        SpoolDirectory(root: spoolDir).write(result(id: id, status: .ready, terminal: UUID()))

        let (exitCode, stdout, stderr) = try runAndCaptureBoth(
            "helm-spool.swift", ["/tmp", "--command", "claude", "--id", id])
        XCTAssertEqual(exitCode, 0, "expected a ready result to succeed, stderr: \(stderr)")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
            "helm-spool.swift's stdout on a ready result was not a JSON object: \(stdout)")
        XCTAssertTrue(
            json["terminalId"] is String,
            "helm-spool.swift: terminalId must be a bare string — no script parses the field "
                + "itself; the script prints this blob verbatim (helm-spool.swift:186) and the "
                + "agent that invoked it reads terminalId out of the printed JSON, so the shape "
                + "is the contract; got \(String(describing: json["terminalId"]))")
        XCTAssertTrue(
            json["handle"] is String,
            "helm-spool.swift: handle must be a bare string — same route, same reason: it "
                + "reaches its reader through the printed blob, not through any script's own "
                + "parse; got \(String(describing: json["handle"]))")
    }

    func testHelmClosePrintsTerminalIdAsABareStringOnceClosed() throws {
        let id = "wire-shape-closed"
        let terminal = UUID()
        SpoolDirectory(root: spoolDir).write(
            result(id: id, status: .closed, terminal: terminal))

        let (exitCode, stdout, stderr) = try runAndCaptureBoth(
            "helm-close.swift", [terminal.uuidString, "--id", id])
        XCTAssertEqual(exitCode, 0, "expected a closed result to succeed, stderr: \(stderr)")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
            "helm-close.swift's stdout on a closed result was not a JSON object: \(stdout)")
        XCTAssertTrue(
            json["terminalId"] is String,
            "helm-close.swift: terminalId must be a bare string; got "
                + "\(String(describing: json["terminalId"]))")
    }

    /// **`helm-close.swift` must name every route to a pane uuid that `HelmWire` names.**
    ///
    /// `CloseRequest.waysToKnowAPane` (#284) is one string precisely because the enumeration used
    /// to be two copies and they disagreed the moment a route was added. The script is a *third*
    /// copy that no constant can reach — it cannot `import HelmWire`, which is this file's whole
    /// subject — so it is checked instead of shared: each route's distinctive marker has to
    /// appear in the `HelmWire` constant **and** in what the script prints, which fails whichever
    /// side falls behind rather than only the far one.
    ///
    /// The markers are deliberately the bare identifiers a caller would search for, not whole
    /// sentences: this is a drift check, not a demand that two prose styles match.
    func testHelmCloseNamesEveryRouteToAPaneUuidThatHelmWireDoes() throws {
        let (exitCode, _, stderr) = try runAndCaptureBoth("helm-close.swift", ["not-a-uuid"])
        XCTAssertEqual(exitCode, 1, "a non-uuid is a usage error, caught before the spool")

        for marker in ["terminalId", "HELM_PANE", "snapshot.json"] {
            XCTAssertTrue(
                CloseRequest.waysToKnowAPane.contains(marker),
                "HelmWire stopped naming \(marker) as a route to a pane uuid — if that is "
                    + "deliberate, this test and helm-close.swift both have to hear about it")
            XCTAssertTrue(
                stderr.contains(marker),
                "helm-close.swift's refusal does not name \(marker), which HelmWire's "
                    + "CloseRequest.waysToKnowAPane does; got \"\(stderr)\"")
        }
    }

    /// A `closed` result with **no `pid`** — the shape #284 made reachable, and the one shape of
    /// a successful close the script had never been handed.
    ///
    /// Every `closed` result before this carried a pid, because every closeable pane had a pty.
    /// A canvas pane has none, so `SpoolModel` writes `pid: pane?.foreground` as absent
    /// (`SpoolResult.Status.closed`'s own header), and `helm-close.swift:164` reads that field by
    /// hand: `(json["pid"] as? Int).map { " — pid \($0) went with it" } ?? ""`. This is the
    /// result direction of the wire, on a branch of the script that no test reached — and the
    /// failure it guards is not an exit code but a **lie in the success message**, which is
    /// exactly what an exit-code assertion cannot see. Both halves are asserted: the close still
    /// succeeds, and it does not claim a process went with it.
    func testHelmCloseOnACanvasSaysThePaneIsGoneWithoutInventingAPidThatDied() throws {
        let id = "wire-shape-closed-no-pid"
        let pane = UUID()
        SpoolDirectory(root: spoolDir).write(
            SpoolResult(id: id, status: .closed, terminalId: TerminalID(pane)))

        let (exitCode, stdout, stderr) = try runAndCaptureBoth(
            "helm-close.swift", [pane.uuidString, "--id", id])
        XCTAssertEqual(exitCode, 0, "a closed result with no pid must still succeed: \(stderr)")
        XCTAssertTrue(
            stderr.contains("pane \(pane.uuidString) is gone"),
            "helm-close.swift must name the pane it closed; got \"\(stderr)\"")
        XCTAssertFalse(
            stderr.contains("went with it"),
            "helm-close.swift must not report a process dying when the result names none — a "
                + "canvas close destroys nothing; got \"\(stderr)\"")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
            "helm-close.swift's stdout was not a JSON object: \(stdout)")
        XCTAssertNil(
            json["pid"],
            "…and the blob it prints verbatim carries no pid either, which is what the agent "
                + "reading it acts on")
    }

    /// **helm-select.swift must name every route to a pane uuid that `HelmWire` names**, for
    /// `testHelmCloseNamesEveryRouteToAPaneUuidThatHelmWireDoes`'s reason exactly: the script is a
    /// copy of `CloseRequest.waysToKnowAPane` that no constant can reach, and #284 is the ticket
    /// where that enumeration proved able to disagree with itself.
    ///
    /// It matters slightly more here than on the close, because the third route — reading the id
    /// out of `snapshot.json` — is the *only* one an agent that pushed an artifact has: `push.sh`
    /// hands back no id, and this script exists precisely for artifacts pushed that way.
    func testHelmSelectNamesEveryRouteToAPaneUuidThatHelmWireDoes() throws {
        let (exitCode, _, stderr) = try runAndCaptureBoth("helm-select.swift", ["not-a-uuid"])
        XCTAssertEqual(exitCode, 1, "a non-uuid is a usage error, caught before the spool")

        for marker in ["terminalId", "HELM_PANE", "snapshot.json"] {
            XCTAssertTrue(
                CloseRequest.waysToKnowAPane.contains(marker),
                "HelmWire stopped naming \(marker) as a route to a pane uuid — if that is "
                    + "deliberate, this test and helm-select.swift both have to hear about it")
            XCTAssertTrue(
                stderr.contains(marker),
                "helm-select.swift's refusal does not name \(marker), which HelmWire's "
                    + "CloseRequest.waysToKnowAPane does; got \"\(stderr)\"")
        }
    }

    /// The focus canary, on the fifth script (#284) — and the reason it is duplicated rather than
    /// assumed from `helm-command`'s: `helm-select.swift` reads `select.focusedPaneBefore` and
    /// `focusedPaneAfter` **by name**, out of a *different* nested object, with no compiler link
    /// to `SelectReport`. Rename either field and both casts return `nil`, `nil == nil` is `true`,
    /// and the one line that would tell a human the focus rule had been broken stops printing.
    ///
    /// The result it is given is a deliberate impossibility — `SpoolSelectPolicy` refuses every
    /// pane whose selection could move the keyboard — which is the point: the branch exists for
    /// the day something slips past, and a branch a real run cannot reach is exactly the one a
    /// test has to.
    func testHelmSelectWarnsWhenAResultSaysFocusMoved() throws {
        let id = "wire-shape-select-focus-moved"
        let pane = UUID()
        let after = UUID()
        SpoolDirectory(root: spoolDir).write(
            SpoolResult(
                id: id, status: .selected, terminalId: TerminalID(pane),
                select: SelectReport(
                    pane: TerminalID(pane), isVisible: true,
                    focusedPaneBefore: TerminalID(pane), focusedPaneAfter: TerminalID(after))))

        let (exitCode, stderr) = try runAndCapture(
            "helm-select.swift", [pane.uuidString, "--id", id])

        XCTAssertEqual(exitCode, 0, "helm did show it, so the script still succeeds — it warns")
        XCTAssertTrue(
            stderr.contains("WARNING: focus MOVED"),
            "helm-select.swift must warn when the two focus readings differ, which is the only "
                + "thing that proves it read them as two fields at all; got \"\(stderr)\"")
        XCTAssertTrue(
            stderr.contains(after.uuidString),
            "…and must name where the keyboard went, so the warning is actionable; got "
                + "\"\(stderr)\"")
    }

    /// **helm-name.swift must name every route to a pane uuid that `HelmWire` names**, for
    /// `testHelmSelectNamesEveryRouteToAPaneUuidThatHelmWireDoes`'s reason exactly — a third
    /// hand-copy of `CloseRequest.waysToKnowAPane` that no constant can reach, in the ticket that
    /// made the third one exist.
    func testHelmNameNamesEveryRouteToAPaneUuidThatHelmWireDoes() throws {
        let (exitCode, _, stderr) = try runAndCaptureBoth(
            "helm-name.swift", ["not-a-uuid", "a name"])
        XCTAssertEqual(exitCode, 1, "a non-uuid is a usage error, caught before the spool")

        for marker in ["terminalId", "HELM_PANE", "snapshot.json"] {
            XCTAssertTrue(
                CloseRequest.waysToKnowAPane.contains(marker),
                "HelmWire stopped naming \(marker) as a route to a pane uuid — if that is "
                    + "deliberate, this test and helm-name.swift both have to hear about it")
            XCTAssertTrue(
                stderr.contains(marker),
                "helm-name.swift's refusal does not name \(marker), which HelmWire's "
                    + "CloseRequest.waysToKnowAPane does; got \"\(stderr)\"")
        }
    }

    /// **The name a `named` result reports is the one the script prints, not the one it sent**
    /// (#313) — `helm-name.swift` reads `name.name` out of a nested object by name, with no
    /// compiler link to `NameReport`, exactly as `helm-select` reads its two focus fields. Rename
    /// the field and the cast returns `nil`, the script quietly falls back to echoing its own
    /// argument, and the one thing that made the report a *measurement* stops working.
    ///
    /// The result it is given deliberately disagrees with what was asked for, which is the only
    /// way to tell "read it back" from "echoed the request".
    func testHelmNamePrintsWhatHelmSaysThePaneIsCalledRatherThanWhatItAskedFor() throws {
        let id = "wire-shape-name-readback"
        let pane = UUID()
        SpoolDirectory(root: spoolDir).write(
            SpoolResult(
                id: id, status: .named, terminalId: TerminalID(pane),
                name: NameReport(
                    pane: TerminalID(pane), previousName: "claude · helm", name: "what helm says"
                )))

        let (exitCode, stderr) = try runAndCapture(
            "helm-name.swift", [pane.uuidString, "what the caller asked for", "--id", id])

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(
            stderr.contains("what helm says"),
            "helm-name.swift must report the name out of the result, which is what the tab "
                + "actually says; got \"\(stderr)\"")
        XCTAssertTrue(
            stderr.contains("claude · helm"),
            "…and must say what it replaced, which is the fact the operator who asked for the "
                + "rename needs; got \"\(stderr)\"")
    }

    /// The control for the test above, and named as one: a script that read neither field would
    /// still print its own argument, so this is what stops that passing. `previousName` is
    /// legitimately absent for a pane nothing had named, and the script must say nothing about
    /// what it replaced rather than inventing a phrase.
    func testHelmNameSaysNothingAboutAPreviousNameWhenThereWasNone() throws {
        let id = "wire-shape-name-first"
        let pane = UUID()
        SpoolDirectory(root: spoolDir).write(
            SpoolResult(
                id: id, status: .named, terminalId: TerminalID(pane),
                name: NameReport(pane: TerminalID(pane), previousName: nil, name: "the plan")))

        let (exitCode, stderr) = try runAndCapture(
            "helm-name.swift", [pane.uuidString, "the plan", "--id", id])

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(stderr.contains("the plan"))
        XCTAssertFalse(
            stderr.contains("was "),
            "a first naming replaced nothing, and saying otherwise would be the script inventing "
                + "a fact; got \"\(stderr)\"")
    }

    /// The control for the test above, and named as one: it passes whether or not the warning
    /// works, because a script that never warns satisfies it. It is here so the test above cannot
    /// be made green by warning unconditionally, which would cry wolf on every ordinary select.
    func testHelmSelectDoesNotWarnWhenFocusStayedPut() throws {
        let id = "wire-shape-select-focus-kept"
        let pane = UUID()
        SpoolDirectory(root: spoolDir).write(result(id: id, status: .selected, terminal: pane))

        let (exitCode, stderr) = try runAndCapture(
            "helm-select.swift", [pane.uuidString, "--id", id])

        XCTAssertEqual(exitCode, 0)
        XCTAssertFalse(
            stderr.contains("WARNING"),
            "a select that kept focus must not warn; got \"\(stderr)\"")
    }

    /// The same property for a `ran` result (#269), and it matters more here than in the two
    /// tests above rather than less: `command.paneCreated` is the field a caller feeds straight
    /// back to `helm-close`, and `helm-command.swift` never parses it — the pane id reaches its
    /// reader only through the blob the script prints verbatim.
    func testHelmCommandPrintsTerminalIdAndPaneCreatedAsBareStringsOnceRan() throws {
        let id = "wire-shape-ran"
        let terminal = UUID()
        SpoolDirectory(root: spoolDir).write(result(id: id, status: .ran, terminal: terminal))

        let (exitCode, stdout, stderr) = try runAndCaptureBoth(
            "helm-command.swift", ["splitRight", "--id", id])
        XCTAssertEqual(exitCode, 0, "expected a ran result to succeed, stderr: \(stderr)")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
            "helm-command.swift's stdout on a ran result was not a JSON object: \(stdout)")
        XCTAssertTrue(
            json["terminalId"] is String,
            "helm-command.swift: terminalId must be a bare string; got "
                + "\(String(describing: json["terminalId"]))")
        let report = try XCTUnwrap(
            json["command"] as? [String: Any], "no command report: \(stdout)")
        XCTAssertTrue(
            report["paneCreated"] is String,
            "helm-command.swift: command.paneCreated must be a bare string — it is what a "
                + "caller passes to helm-close next; got \(String(describing: report["paneCreated"]))"
        )
        XCTAssertEqual(
            report["command"] as? String, "splitRight",
            "…and the command name is its raw value, the same string the script takes on its "
                + "own command line")
        for field in ["focusedPaneBefore", "focusedPaneAfter"] {
            XCTAssertTrue(
                report[field] is String,
                "helm-command.swift: command.\(field) must be a bare string — the script reads "
                    + "it by name to decide whether to warn that focus moved; got "
                    + "\(String(describing: report[field]))")
        }
    }

    /// **The focus warning is a canary, and a canary nobody tests is a canary that can die
    /// quietly.** `helm-command.swift:181-185` reads `focusedPaneBefore` and `focusedPaneAfter`
    /// out of the result **by name**, with no compiler link to `CommandReport` — it cannot
    /// `import HelmWire`. Rename either field and both casts return `nil`, `nil == nil` is
    /// `true`, and the one line that would tell a human the focus rule had been broken silently
    /// stops printing. The shape assertions in the test above catch a *type* change; only this
    /// catches a *name* change, because it is the only thing here that depends on the two fields
    /// having been read as two different values.
    ///
    /// The result it is given is a deliberate impossibility — `SpoolCommandPolicy` allows no
    /// command that moves focus, so no real helm writes one. That is the point: the branch
    /// exists for the day something does, and a branch a real run cannot reach is exactly the
    /// one a test has to.
    func testHelmCommandWarnsWhenAResultSaysFocusMoved() throws {
        let id = "wire-shape-focus-moved"
        let before = UUID()
        let after = UUID()
        SpoolDirectory(root: spoolDir).write(
            SpoolResult(
                id: id, status: .ran,
                command: CommandReport(
                    command: .splitRight, paneCreated: nil,
                    focusedPaneBefore: TerminalID(before), focusedPaneAfter: TerminalID(after),
                    columns: 1, panes: 1)))

        let (exitCode, stderr) = try runAndCapture(
            "helm-command.swift", ["splitRight", "--id", id])

        XCTAssertEqual(exitCode, 0, "helm ran it, so the script still succeeds — it only warns")
        XCTAssertTrue(
            stderr.contains("WARNING: focus MOVED"),
            "helm-command.swift must warn when the two focus readings differ, which is the only "
                + "thing that proves it read them as two fields at all; got \"\(stderr)\"")
        XCTAssertTrue(
            stderr.contains(before.uuidString) && stderr.contains(after.uuidString),
            "…and must name both panes, so the warning is actionable; got \"\(stderr)\"")
    }

    /// The other half of the pair, and named as a **control**: it passes whether or not the
    /// warning works, because a script that never warns satisfies it. It is here so that the
    /// test above cannot be made green by warning unconditionally — which would be the cheapest
    /// wrong fix, and would cry wolf on every ordinary command.
    func testHelmCommandDoesNotWarnWhenFocusStayedPut() throws {
        let id = "wire-shape-focus-kept"
        let terminal = UUID()
        SpoolDirectory(root: spoolDir).write(result(id: id, status: .ran, terminal: terminal))

        let (exitCode, stderr) = try runAndCapture(
            "helm-command.swift", ["splitRight", "--id", id])

        XCTAssertEqual(exitCode, 0)
        XCTAssertFalse(
            stderr.contains("WARNING"),
            "an allowed command that kept focus must not warn; got \"\(stderr)\"")
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
        let deadline = Date().addingTimeInterval(Self.scriptBudget)
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
        _ script: String, _ arguments: [String], timeout: TimeInterval = scriptBudget
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

    /// Same shape as `runAndCapture`, but also returns stdout — every other test here only
    /// needs the exit code and stderr, but the wire-shape tests (#229) need to inspect the
    /// actual JSON a script printed back, which each of them writes to stdout right before
    /// switching on `status` (`helm-spool.swift:186`, `helm-close.swift:153`).
    private func runAndCaptureBoth(
        _ script: String, _ arguments: [String], timeout: TimeInterval = scriptBudget
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
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
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
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
        process.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus, String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Waits for `<spoolDir>/<id>.json` to appear, then decodes it exactly as
    /// `SpoolModel.drain()` does in the real app — `SpoolDirectory.request(at:)`, not a decoder
    /// hand-rolled for this test.
    ///
    /// Polling for the *final* name rather than reading as soon as anything shows up is what
    /// keeps this from ever reading a half-written file: every script writes under a dot name
    /// and renames into place, so the final name existing at all means the write is whole.
    private func decodedRequest(
        id: String, timeout: TimeInterval = scriptBudget
    ) throws -> SpoolRequest {
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

    /// **Says which of the two things it is, because it cannot tell and the reader can.**
    ///
    /// A red in this suite means "the spool wire drifted", which is the loudest thing it can
    /// say — so when the cause is instead a machine too busy to compile a one-file script
    /// inside the budget, the message has to offer that reading rather than leave a diff to
    /// take the blame. #291 is that mistake made twice: once locally under agent load, once on
    /// a cold CI runner, both on branches touching no file this suite reads.
    private struct ScriptNeverExited: Error, CustomStringConvertible {
        let script: String
        let timeout: TimeInterval
        var description: String {
            "\(script) was still running \(timeout)s after being given a terminal result — it "
                + "should have answered and exited. This budget covers `swift <file>` compiling "
                + "the script as well as running it, so a cold or heavily loaded machine can "
                + "reach it without anything having drifted (#291). Before reading this as a "
                + "wire-format failure, re-run it on a quiet machine."
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
