import HelmWire
import XCTest

@testable import Helm

/// The gate on untrusted input, and the line helm composes once a request is through it.
///
/// A spool request is a *file*, so anything that can write a file is a caller. Every rule here
/// is what stands between that and a login shell with the operator's whole environment.
final class SpoolPolicyTests: XCTestCase {
    private static let captures = URL(fileURLWithPath: "/tmp/spool/captures")

    private func request(
        id: String = "req-1", cwd: String = "/tmp", command: String = "claude",
        args: [String] = [], prompt: String? = nil
    ) -> SpoolRequest {
        .spawn(SpawnRequest(id: id, cwd: cwd, command: command, args: args, prompt: prompt))
    }

    private func accept(_ request: SpoolRequest) throws -> AcceptedSpawnRequest {
        guard case .spawn(let accepted) = try work(request) else {
            throw SpoolRefusal("expected a spawn")
        }
        return accepted
    }

    private func work(_ request: SpoolRequest) throws -> SpoolWork {
        try SpoolPolicy.accept(
            request, captures: Self.captures,
            isDirectory: {
                ["/tmp", "/tmp/work", "/tmp/shots"].contains($0)
            }
        ).get()
    }

    private func refusal(_ request: SpoolRequest) -> String? {
        if case .failure(let refusal) = SpoolPolicy.accept(
            request, captures: Self.captures,
            isDirectory: { ["/tmp", "/tmp/work", "/tmp/shots"].contains($0) })
        {
            return refusal.reason
        }
        return nil
    }

    func testAnAgentInAnExistingDirectoryIsAccepted() throws {
        let accepted = try accept(request(cwd: "/tmp/work/", prompt: "hello"))
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
        XCTAssertNil(try accept(request(prompt: "")).prompt)
    }

    // MARK: - Nobody is at the pane (#179)

    func testAClaudeRequestThatSaysNothingAboutPermissionsStillProducesAWorkingAgent() throws {
        // The bug: a bare `claude` sits at a permission prompt in a pane nobody is watching, so
        // the spawn is indistinguishable from one that never happened. Measured — the pid had
        // no child and never created its worktree.
        let accepted = try accept(request(command: "claude"))
        XCTAssertEqual(accepted.args, ["--dangerously-skip-permissions"])
    }

    func testTheSpoolAndTheGuiPathAgreeAboutStartingAClaudeAgent() throws {
        // `helm-spawn` types `cls`, which is `claude --dangerously-skip-permissions`. Two spawn
        // paths that disagree about what "start a Claude agent" means is the defect.
        let accepted = try accept(request(command: "claude"))
        XCTAssertEqual(
            SpoolLaunchLine.compose(accepted, promptPath: nil),
            "'claude' '--dangerously-skip-permissions'")
    }

    func testThePostureGoesOnEvenWhenTheRequestBroughtUnrelatedArguments() throws {
        // "Passed no arguments" is not "thought about permissions". A request for
        // `claude --model opus` never mentioned them, and is the hardest hang to notice.
        let accepted = try accept(request(command: "claude", args: ["--model", "opus"]))
        XCTAssertEqual(
            accepted.args, ["--dangerously-skip-permissions", "--model", "opus"])
    }

    func testARequestThatHasDecidedForItselfIsLeftAlone() throws {
        // The escape hatch is the request's own, and it is not a helm setting. Both spellings
        // of a flag with a value count, and the flag helm would have added is not doubled.
        for args in [
            ["--permission-mode", "plan"], ["--permission-mode=plan"],
            ["--dangerously-skip-permissions"],
        ] {
            XCTAssertEqual(
                try accept(request(command: "claude", args: args)).args, args,
                "\(args) settles the question, so helm adds nothing")
        }
    }

    func testCodexGetsTheProfileThatCdxyGets() throws {
        // `cdxy` is `codex -p yolo`, and `~/.codex/yolo.config.toml` is approval_policy=never
        // with sandbox_mode=danger-full-access. The operator's standing choice for codex, the
        // same way `--dangerously-skip-permissions` is his for claude.
        XCTAssertEqual(try accept(request(command: "codex")).args, ["-p", "yolo"])
    }

    func testARequestThatChoseItsOwnCodexProfileKeepsIt() throws {
        // `-p` is in codex's `settled` set *and* in its posture, so the two must never be the
        // same `-p`: `settled` is matched against what the request asked for, never against
        // the composed line. If that order ever inverted, helm's own `-p` would answer its own
        // question and every codex posture would silently cancel itself.
        XCTAssertEqual(
            try accept(request(command: "codex", args: ["-p", "something-else"])).args,
            ["-p", "something-else"])
        XCTAssertEqual(
            try accept(request(command: "codex", args: ["--profile=read-only"])).args,
            ["--profile=read-only"])
        XCTAssertEqual(
            try accept(request(command: "codex", args: ["--ask-for-approval", "untrusted"]))
                .args,
            ["--ask-for-approval", "untrusted"])
    }

    func testPiIsGivenTheProjectItWasPointedAt() throws {
        // pi never asks "may I act?" — no sandbox, no per-tool prompt. It asks whether to load
        // the project's settings, extensions and skills, and hangs when nobody answers.
        // Declining would not block anything; it would start an agent silently missing the
        // project it was spawned for, which is a quieter version of the bug being fixed.
        XCTAssertEqual(try accept(request(command: "pi")).args, ["--approve"])
        XCTAssertEqual(
            try accept(request(command: "pi", args: ["-na"])).args, ["-na"],
            "a caller that wants the other answer says so, where it is auditable")
    }

    func testNoPostureWithholdsCapabilityToFeelSafe() {
        // The operator's principle, pinned: an approval prompt is theatre, and blocking belongs
        // in hooks and sandboxes rather than in a spawn posture. A posture that hobbles an
        // agent produces failures nobody watches, which is the whole of #179 — so no posture
        // here may be a flag whose effect is "do less".
        let withholding: Set<String> = ["--no-approve", "-na", "--sandbox", "read-only"]
        for (command, posture) in SpoolUnattendedPolicy.postures {
            XCTAssertTrue(
                Set(posture.arguments).isDisjoint(with: withholding),
                "\(command)'s posture takes capability away rather than removing a prompt")
        }
    }

    func testEveryAgentHelmWillStartHasAnAnswerForAnEmptyPane() {
        // The drift guard. An allowed command with no posture is a silent hang the day it is
        // added, which is the whole bug — so the two sets are one decision, not two.
        //
        // **Still a true invariant under the kinds split (#174), and worth saying why rather
        // than leaving it to look like a coincidence.** `allowedCommands` gates
        // `SpawnRequest.command` and nothing else: a capture carries no command, so it can
        // neither widen this set nor need a posture. The two sets are one decision because
        // both are about *starting an agent*, which is what the spawn kind is.
        XCTAssertEqual(
            Set(SpoolUnattendedPolicy.postures.keys), SpoolPolicy.allowedCommands)
    }

    func testAKindIsRoutedByItsKindRatherThanByTheFieldsItHappensToCarry() throws {
        // **What the kinds split actually put at risk, and the one thing here that was not
        // already covered.** `allowedCommands` is the only thing standing between a spool file
        // and a login shell, and it is reached only down the spawn arm. A request that says
        // `capture` while carrying a `command` must take the capture arm on the strength of its
        // `kind` — if the envelope ever routed on "does it have a command?", this file would be
        // a way to run `sh` that never passed the allowlist at all.
        let smuggled = try JSONDecoder().decode(
            SpoolRequest.self,
            from: Data(#"{"id":"x","kind":"capture","command":"sh","cwd":"/tmp"}"#.utf8))
        guard case .capture = try work(smuggled) else {
            return XCTFail("a capture must stay a capture whatever else the file carries")
        }
        // And the reverse: the accepted capture has no command and no args to put a posture on,
        // which the compiler enforces — `AcceptedCaptureRequest` has neither field.
        XCTAssertEqual(try accepted(smuggled).path, "/tmp/spool/captures/x.png")
    }

    func testTheAllowlistIsNotWidenedIntoTheOperatorsShellScripts() {
        // `cls` is `claude --dangerously-skip-permissions` on the operator's PATH, and naming
        // it here would have been the easy fix. It is a script this repo does not define,
        // cannot test and cannot pin — the flag is the same behaviour without handing the
        // allowlist's meaning to something outside the repo.
        for shim in ["cls", "cld", "ccc", "cdxy"] {
            XCTAssertNotNil(refusal(request(command: shim)), "\(shim) is not a program helm pins")
        }
    }

    // MARK: - The launch line

    func testTheLaunchLineHandsOverAPathRatherThanThePromptItself() {
        let accepted = AcceptedSpawnRequest(
            id: "r", cwd: "/tmp", command: "claude",
            args: ["--dangerously-skip-permissions"], prompt: "/review the diff")
        let line = SpoolLaunchLine.compose(accepted, promptPath: "/tmp/spool/prompts/r.txt")
        XCTAssertEqual(
            line,
            "'claude' '--dangerously-skip-permissions' "
                + "'\(SpoolLaunchLine.promptPointer(to: "/tmp/spool/prompts/r.txt"))'")
        // A prompt beginning with `/`, or holding quotes or newlines, never reaches the shell's
        // word splitting — which is what makes all three ordinary rather than three hazards.
        XCTAssertFalse(line.contains("/review the diff"))
    }

    func testTheLaunchLineNeverAsksTheShellToExpandThePrompt() {
        // `"$(cat …)"` is a command substitution, and the shell resolves it BEFORE exec — so the
        // fully expanded prompt became an argv element of the agent (#93). The old test asserted
        // on the *line* and passed, because the defect is in what the shell makes of the line.
        let accepted = AcceptedSpawnRequest(
            id: "r", cwd: "/tmp", command: "claude", args: [], prompt: "secret")
        let line = SpoolLaunchLine.compose(accepted, promptPath: "/tmp/spool/prompts/r.txt")
        XCTAssertFalse(
            line.contains("$("),
            "no command substitution may survive here — the shell expands it into argv")
        XCTAssertFalse(line.contains("`"), "backticks are a command substitution too")
    }

    func testTheAgentIsPointedAtTheFileInWordsItCanActOn() {
        let pointer = SpoolLaunchLine.promptPointer(to: "/tmp/spool/prompts/r.txt")
        XCTAssertTrue(pointer.contains("/tmp/spool/prompts/r.txt"))
        // Delivery is now the agent's own first act, so the sentence has to say "read it and do
        // it" rather than leaving the file as background reading.
        XCTAssertTrue(pointer.lowercased().contains("read it now"))
        // A bystander that greps the process table is told the line is not theirs, which is the
        // second half of #93: two agents on one machine is prompt injection with no attacker.
        XCTAssertTrue(pointer.contains("not addressed to you"))
        // It goes through `quoted`, and an apostrophe there would be escaped rather than broken —
        // but the typed line is read by humans in refusals, so keep it free of shell metacharacters.
        XCTAssertFalse(pointer.contains("'"))
    }

    /// **The measurement the string assertions above cannot make.** The defect is not in the text
    /// helm composes, it is in what a *shell* does with that text, so this runs one: a stand-in
    /// program that prints its own argv, launched exactly the way helm launches an agent.
    ///
    /// Red against the `"$(cat …)"` line — the prompt comes back as argv[1].
    func testAShellRunningTheLaunchLineNeverPutsThePromptInTheAgentsArgv() throws {
        let secret = "PROMPT-SECRET-\(UUID().uuidString) do the thing"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-line-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let promptPath = directory.appendingPathComponent("prompt.txt")
        try secret.write(to: promptPath, atomically: true, encoding: .utf8)
        let agent = directory.appendingPathComponent("argv-printer")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n"
            .write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: agent.path)

        let accepted = AcceptedSpawnRequest(
            id: "r", cwd: directory.path, command: agent.path, args: [], prompt: secret)
        let line = SpoolLaunchLine.compose(accepted, promptPath: promptPath.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let argv = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertFalse(
            argv.contains(where: { $0.contains(secret) }),
            "the agent's argv carried the prompt, which is what `ps` reads (#93): \(argv)")
        XCTAssertTrue(
            argv.contains(where: { $0.contains(promptPath.path) }),
            "argv must carry the path instead, or the agent has nothing to read: \(argv)")
    }

    func testNoPromptMeansNoTrailingArgument() {
        let accepted = AcceptedSpawnRequest(
            id: "r", cwd: "/tmp", command: "pi", args: [], prompt: nil)
        XCTAssertEqual(SpoolLaunchLine.compose(accepted, promptPath: nil), "'pi'")
    }

    func testQuotingSurvivesAnEmbeddedSingleQuote() {
        // The only escaping rule a POSIX shell has no exceptions to: close, escape, reopen.
        XCTAssertEqual(SpoolLaunchLine.quoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(SpoolLaunchLine.quoted("; rm -rf /"), "'; rm -rf /'")
    }

    // MARK: - Capture (#174)

    private func capture(
        id: String = "shot-1", path: String? = nil, window: String? = nil
    )
        -> SpoolRequest
    {
        .capture(CaptureRequest(id: id, path: path, window: window))
    }

    private func accepted(_ request: SpoolRequest) throws -> AcceptedCaptureRequest {
        guard case .capture(let accepted) = try work(request) else {
            throw SpoolRefusal("expected a capture")
        }
        return accepted
    }

    func testACaptureWithNoPathLandsInTheSpoolsOwnCapturesDirectory() throws {
        // The common case asks for no permission at all: the caller already writes to the
        // spool, so a default inside it is somewhere it can certainly read back.
        XCTAssertEqual(try accepted(capture()).path, "/tmp/spool/captures/shot-1.png")
    }

    func testANamedPathMustBeAbsoluteAndAPngInADirectoryThatExists() throws {
        XCTAssertEqual(
            try accepted(capture(path: "/tmp/shots/bench.png")).path, "/tmp/shots/bench.png")
        // Relative — helm has no working directory a caller can reason about.
        XCTAssertNotNil(refusal(capture(path: "bench.png")))
        // Not a PNG. The result promises one, so a caller reading `capture.path` should not
        // have to check what it actually got.
        XCTAssertNotNil(refusal(capture(path: "/tmp/shots/bench.txt")))
        // A directory helm would have to create. Creating directories on a caller's word is a
        // different capability than the one #174 asks for.
        XCTAssertNotNil(refusal(capture(path: "/tmp/nowhere/bench.png")))
    }

    func testACaptureIdIsGatedAsAFilenameLikeEveryOtherRequest() {
        // `captures/<id>.png` as well as `results/<id>.json` now, so an ungated id writes two
        // files wherever the caller likes rather than one.
        XCTAssertNotNil(refusal(capture(id: "../../../etc/x")))
        XCTAssertNil(refusal(capture(id: "capture-2026-08-04")))
    }

    func testAnEmptyWindowIsNoWindowAtAll() throws {
        // Otherwise it becomes a title filter matching everything, which is a different
        // question than "I do not care which".
        XCTAssertNil(try accepted(capture(window: "   ")).window)
        XCTAssertEqual(try accepted(capture(window: "helm-bench")).window, "helm-bench")
    }

    // MARK: - The envelope

    func testAKindHelmDoesNotKnowIsRefusedByNameRatherThanDropped() throws {
        // A decoder that threw here would make "helm is older than this request" look exactly
        // like "this file is not JSON", and the caller would be told the wrong thing to fix.
        let request = try JSONDecoder().decode(
            SpoolRequest.self, from: Data(#"{"id":"x","kind":"teleport"}"#.utf8))
        XCTAssertEqual(request, .unrecognised(id: "x", kind: "teleport"))
        XCTAssertEqual(refusal(request)?.contains("teleport"), true)
    }

    func testARequestWithNoKindIsStillASpawn() throws {
        // Every request written before #174 omits `kind`, and those requests still mean what
        // they meant.
        let request = try JSONDecoder().decode(
            SpoolRequest.self,
            from: Data(#"{"id":"x","cwd":"/tmp","command":"claude"}"#.utf8))
        XCTAssertEqual(request, .spawn(SpawnRequest(id: "x", cwd: "/tmp", command: "claude")))
    }

    func testACaptureNeedsNoCwdOrCommand() throws {
        // The reason `SpoolRequest` is an enum rather than one struct with optional fields: a
        // capture genuinely has no cwd, and decoding it into a spawn shape would throw.
        let request = try JSONDecoder().decode(
            SpoolRequest.self, from: Data(#"{"id":"x","kind":"capture"}"#.utf8))
        XCTAssertEqual(request, .capture(CaptureRequest(id: "x")))
    }

    // MARK: - Close (#176)

    func testACloseNamesAPaneAndDefaultsToNotForcing() throws {
        // `force` absent means false, and it has to: a request that forgot to mention it is a
        // request that never thought about destroying live work, which is the case the default
        // exists for.
        let request = try JSONDecoder().decode(
            SpoolRequest.self,
            from: Data(
                #"{"id":"x","kind":"close","terminal":"1E5B7B1C-0000-4000-8000-00000000ABCD"}"#
                    .utf8))
        XCTAssertEqual(
            request,
            .close(CloseRequest(id: "x", terminal: "1E5B7B1C-0000-4000-8000-00000000ABCD")))
        guard case .close(let accepted) = try work(request) else {
            return XCTFail("expected a close")
        }
        XCTAssertEqual(accepted.terminal.uuidString, "1E5B7B1C-0000-4000-8000-00000000ABCD")
        XCTAssertFalse(accepted.force)
    }

    func testATerminalThatIsNotAUuidIsRefusedRatherThanMatchingNothing() {
        // The two are indistinguishable to a caller — "helm closed nothing" — and exactly one
        // of them is a typo it could fix.
        for terminal in ["", "not-a-uuid", "1E5B7B1C-0000-4000-8000", "  "] {
            XCTAssertNotNil(
                refusal(.close(CloseRequest(id: "x", terminal: terminal))),
                "\(terminal) must be refused as a pane id")
        }
    }

    func testACloseIsRoutedByItsKindAndCarriesNoCommandOfItsOwn() throws {
        // The same pinning `capture` gets, and #176 is the kind that most needs it: it is the
        // destructive one, and a `close` that could take the spawn arm on the strength of a
        // stray `command` would be a file that both starts `sh` and never met `allowedCommands`.
        let smuggled = try JSONDecoder().decode(
            SpoolRequest.self,
            from: Data(
                #"{"id":"x","kind":"close","terminal":"1E5B7B1C-0000-4000-8000-00000000ABCD","command":"sh","cwd":"/tmp"}"#
                    .utf8))
        guard case .close(let accepted) = try work(smuggled) else {
            return XCTFail("a close must stay a close whatever else the file carries")
        }
        // And there is nowhere for a command to survive to: `AcceptedCloseRequest` has no such
        // field, which the compiler enforces rather than this assertion.
        XCTAssertEqual(accepted.terminal.uuidString, "1E5B7B1C-0000-4000-8000-00000000ABCD")
    }

    // MARK: - Select (#284)

    func testASelectNamesAPaneAndCarriesNothingElse() throws {
        // The whole request, and the reason it is a kind rather than a command: it carries an
        // address, which is the one thing `CommandRequest` cannot.
        let request = try JSONDecoder().decode(
            SpoolRequest.self,
            from: Data(
                #"{"id":"x","kind":"select","pane":"1E5B7B1C-0000-4000-8000-00000000ABCD"}"#.utf8))
        XCTAssertEqual(
            request,
            .select(SelectRequest(id: "x", pane: "1E5B7B1C-0000-4000-8000-00000000ABCD")))
        guard case .select(let accepted) = try work(request) else {
            return XCTFail("expected a select")
        }
        XCTAssertEqual(accepted.pane.uuidString, "1E5B7B1C-0000-4000-8000-00000000ABCD")
    }

    func testAPaneThatIsNotAUuidIsRefusedRatherThanMatchingNothing() {
        // The same argument `testATerminalThatIsNotAUuidIsRefusedRatherThanMatchingNothing`
        // makes for a close: "helm showed nothing" and "that is a typo" are indistinguishable to
        // a caller, and exactly one of them is fixable.
        for pane in ["", "not-a-uuid", "1E5B7B1C-0000-4000-8000", "  "] {
            XCTAssertNotNil(
                refusal(.select(SelectRequest(id: "x", pane: pane))),
                "\(pane) must be refused as a pane id")
        }
    }

    func testASelectIsRoutedByItsKindAndCarriesNoCommandOfItsOwn() throws {
        // The pinning every kind gets, and for the same reason: a `select` that could take the
        // spawn arm on the strength of a stray `command` would be a file that starts `sh` and
        // never met `allowedCommands`.
        let smuggled = try JSONDecoder().decode(
            SpoolRequest.self,
            from: Data(
                #"{"id":"x","kind":"select","pane":"1E5B7B1C-0000-4000-8000-00000000ABCD","command":"sh","cwd":"/tmp","force":true}"#
                    .utf8))
        guard case .select(let accepted) = try work(smuggled) else {
            return XCTFail("a select must stay a select whatever else the file carries")
        }
        // And there is nowhere for a command — or a `force` — to survive to: `AcceptedSelect
        // Request` has neither field, which the compiler enforces rather than this assertion.
        XCTAssertEqual(accepted.pane.uuidString, "1E5B7B1C-0000-4000-8000-00000000ABCD")
    }

    // MARK: - Name (#313)

    func testANameNamesAPaneAndCarriesWhatToCallIt() throws {
        let request = try JSONDecoder().decode(
            SpoolRequest.self,
            from: Data(
                #"{"id":"x","kind":"name","pane":"1E5B7B1C-0000-4000-8000-00000000ABCD","name":"review the diff"}"#
                    .utf8))
        XCTAssertEqual(
            request,
            .name(
                NameRequest(
                    id: "x", pane: "1E5B7B1C-0000-4000-8000-00000000ABCD",
                    name: "review the diff")))
        guard case .name(let accepted) = try work(request) else {
            return XCTFail("expected a name")
        }
        XCTAssertEqual(accepted.pane.uuidString, "1E5B7B1C-0000-4000-8000-00000000ABCD")
        XCTAssertEqual(accepted.name, "review the diff")
        XCTAssertFalse(
            accepted.rename,
            "an absent `rename` is the safe answer, exactly as an absent `force` is on a close")
    }

    func testANameThatIsNotAPaneUuidIsRefusedRatherThanMatchingNothing() {
        // The third copy of an argument that is now written once — `SpoolPolicy.pane` — and the
        // test is per kind because the *field name* in the refusal is per kind.
        for pane in ["", "not-a-uuid", "1E5B7B1C-0000-4000-8000", "  "] {
            XCTAssertNotNil(
                refusal(.name(NameRequest(id: "x", pane: pane, name: "anything"))),
                "\(pane) must be refused as a pane id")
        }
    }

    func testANameHelmWillNotDrawIsRefusedWithItsOwnReason() throws {
        // `SpoolPolicy`'s half of #313 — the shape of the value, where `SpoolNamePolicy` owns who
        // may replace what. Both are refusals, and telling them apart is what the reasons do.
        let pane = "1E5B7B1C-0000-4000-8000-00000000ABCD"
        let empty = try XCTUnwrap(
            refusal(.name(NameRequest(id: "x", pane: pane, name: "   "))))
        XCTAssertTrue(
            empty.contains("has to be something"),
            "an empty name is not read as *clear it* — nothing asked for that, and helm cannot "
                + "tell it from a caller that forgot the argument")

        let long = String(repeating: "a", count: SpoolPolicy.maxNameLength + 1)
        XCTAssertNotNil(refusal(.name(NameRequest(id: "x", pane: pane, name: long))))
        XCTAssertNil(
            refusal(
                .name(
                    NameRequest(
                        id: "x", pane: pane,
                        name: String(repeating: "a", count: SpoolPolicy.maxNameLength)))),
            "…and the bound itself is allowed, or the message would be off by one")

        XCTAssertNotNil(
            refusal(.name(NameRequest(id: "x", pane: pane, name: "two\nlines"))),
            "a control character in a value drawn on a tab and read back out of a result file is "
                + "refused, exactly as one in a spawn's args is")
    }

    func testANameIsTrimmedOnceHereRatherThanAtEveryReader() throws {
        // `AcceptedCaptureRequest.path`'s argument: the one place that decides what a pane will
        // be called is the one place that checked whether it may be.
        guard
            case .name(let accepted) = try work(
                .name(
                    NameRequest(
                        id: "x", pane: "1E5B7B1C-0000-4000-8000-00000000ABCD",
                        name: "  review the diff  ")))
        else { return XCTFail("expected a name") }
        XCTAssertEqual(accepted.name, "review the diff")
    }

    func testANameIsRoutedByItsKindAndCarriesNoCommandOfItsOwn() throws {
        // The pinning every kind gets, and for the same reason: a `name` that could take the
        // spawn arm on the strength of a stray `command` would be a file that starts `sh` and
        // never met `allowedCommands`.
        let smuggled = try JSONDecoder().decode(
            SpoolRequest.self,
            from: Data(
                #"{"id":"x","kind":"name","pane":"1E5B7B1C-0000-4000-8000-00000000ABCD","name":"n","command":"sh","cwd":"/tmp","force":true}"#
                    .utf8))
        guard case .name(let accepted) = try work(smuggled) else {
            return XCTFail("a name must stay a name whatever else the file carries")
        }
        // And there is nowhere for a command — or a `force` — to survive to: `AcceptedNameRequest`
        // has neither field, which the compiler enforces rather than this assertion.
        XCTAssertEqual(accepted.pane.uuidString, "1E5B7B1C-0000-4000-8000-00000000ABCD")
    }

    // MARK: - What the three addressed kinds now share (#313)

    func testEveryAddressedKindNamesTheSameRoutesToAPaneUuid() {
        // The extraction, held: `SpoolPolicy.pane` is one function, and before #313 the same
        // eight lines were written twice with one word changed. A third copy is what this stops.
        let bad = "not-a-uuid"
        let reasons = [
            refusal(.close(CloseRequest(id: "x", terminal: bad))),
            refusal(.select(SelectRequest(id: "x", pane: bad))),
            refusal(.name(NameRequest(id: "x", pane: bad, name: "n"))),
        ]
        for reason in reasons {
            let reason = reason ?? ""
            XCTAssertTrue(
                reason.contains(CloseRequest.waysToKnowAPane),
                "every addressed kind hands back the one list of routes; got \"\(reason)\"")
        }
        XCTAssertTrue(reasons[0]?.contains("terminal \"not-a-uuid\"") == true)
        XCTAssertTrue(
            reasons[1]?.contains("pane \"not-a-uuid\"") == true,
            "…while still naming the field the caller actually wrote, which is the one thing the "
                + "shared helper takes as a parameter")
        XCTAssertTrue(reasons[2]?.contains("pane \"not-a-uuid\"") == true)
    }

    func testTheNoSuchPaneRefusalIsOneSentenceForAllThreePolicies() {
        // The second extraction, held. Before #313 the close's copy was missing the
        // parked-workspace sentence the select's carried, and it was true of both.
        let pane = TerminalID(UUID())
        let reasons = [
            SpoolClosePolicy.refusal(
                for: AcceptedCloseRequest(id: "x", terminal: pane, force: false), pane: nil),
            SpoolSelectPolicy.refusal(
                for: AcceptedSelectRequest(id: "x", pane: pane), pane: nil),
            SpoolNamePolicy.refusal(
                for: AcceptedNameRequest(id: "x", pane: pane, name: "n", rename: false),
                pane: nil),
        ]
        for reason in reasons {
            XCTAssertEqual(reason, SpoolRefusal.noSuchPane(pane))
        }
        XCTAssertTrue(
            SpoolRefusal.noSuchPane(pane).reason.contains("parked"),
            "including the sentence a close used to be missing")
    }

    /// **The refusal for a file that does not parse at all has to describe every kind**, because
    /// it is the one answer with no `kind` to route on — the caller's JSON was never readable, so
    /// helm cannot know which shape they were aiming at.
    ///
    /// `SpoolRequest.wireShapes` is what `SpoolModel.drain` sends, and this is `kinds`' own test
    /// one level down: the list that says *which* kinds exist is already pinned above, and this
    /// pins that each of them also says *what its file looks like*. Before #284 those shapes were
    /// five string literals inside `SpoolModel`, so a sixth kind could arrive with a message
    /// describing five and nothing anywhere would notice.
    func testEveryKindHelmKnowsDescribesItsOwnFileShape() {
        for kind in SpoolRequest.kinds {
            XCTAssertTrue(
                SpoolRequest.wireShapes.contains(kind),
                "\(kind) is a kind helm knows but wireShapes does not describe it, so a caller "
                    + "whose JSON would not parse is told about every kind except theirs")
        }
        // Each shape names the one field every request carries, which is what makes the entries
        // descriptions of a *file* rather than a list of kind names a second time.
        XCTAssertEqual(
            SpoolRequest.wireShapes.components(separatedBy: "\"id\"").count - 1,
            SpoolRequest.kinds.count)
    }

    func testEveryKindHelmKnowsIsNamedInTheRefusalForTheOnesItDoesNot() throws {
        // A third kind arriving with a refusal message that still says there are two is the
        // drift this list exists to stop.
        let unknown = try JSONDecoder().decode(
            SpoolRequest.self, from: Data(#"{"id":"x","kind":"teleport"}"#.utf8))
        let reason = try XCTUnwrap(refusal(unknown))
        for kind in SpoolRequest.kinds {
            XCTAssertTrue(reason.contains(kind), "\(kind) must be named as an allowed kind")
        }
    }
}
