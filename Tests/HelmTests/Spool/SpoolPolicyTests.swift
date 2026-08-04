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
        let accepted = try accept(request(command: "claude")).get()
        XCTAssertEqual(accepted.args, ["--dangerously-skip-permissions"])
    }

    func testTheSpoolAndTheGuiPathAgreeAboutStartingAClaudeAgent() throws {
        // `helm-spawn` types `cls`, which is `claude --dangerously-skip-permissions`. Two spawn
        // paths that disagree about what "start a Claude agent" means is the defect.
        let accepted = try accept(request(command: "claude")).get()
        XCTAssertEqual(
            SpoolLaunchLine.compose(accepted, promptPath: nil),
            "'claude' '--dangerously-skip-permissions'")
    }

    func testThePostureGoesOnEvenWhenTheRequestBroughtUnrelatedArguments() throws {
        // "Passed no arguments" is not "thought about permissions". A request for
        // `claude --model opus` never mentioned them, and is the hardest hang to notice.
        let accepted = try accept(request(command: "claude", args: ["--model", "opus"])).get()
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
                try accept(request(command: "claude", args: args)).get().args, args,
                "\(args) settles the question, so helm adds nothing")
        }
    }

    func testCodexGetsTheProfileThatCdxyGets() throws {
        // `cdxy` is `codex -p yolo`, and `~/.codex/yolo.config.toml` is approval_policy=never
        // with sandbox_mode=danger-full-access. The operator's standing choice for codex, the
        // same way `--dangerously-skip-permissions` is his for claude.
        XCTAssertEqual(try accept(request(command: "codex")).get().args, ["-p", "yolo"])
    }

    func testARequestThatChoseItsOwnCodexProfileKeepsIt() throws {
        // `-p` is in codex's `settled` set *and* in its posture, so the two must never be the
        // same `-p`: `settled` is matched against what the request asked for, never against
        // the composed line. If that order ever inverted, helm's own `-p` would answer its own
        // question and every codex posture would silently cancel itself.
        XCTAssertEqual(
            try accept(request(command: "codex", args: ["-p", "something-else"])).get().args,
            ["-p", "something-else"])
        XCTAssertEqual(
            try accept(request(command: "codex", args: ["--profile=read-only"])).get().args,
            ["--profile=read-only"])
        XCTAssertEqual(
            try accept(request(command: "codex", args: ["--ask-for-approval", "untrusted"]))
                .get().args,
            ["--ask-for-approval", "untrusted"])
    }

    func testPiIsGivenTheProjectItWasPointedAt() throws {
        // pi never asks "may I act?" — no sandbox, no per-tool prompt. It asks whether to load
        // the project's settings, extensions and skills, and hangs when nobody answers.
        // Declining would not block anything; it would start an agent silently missing the
        // project it was spawned for, which is a quieter version of the bug being fixed.
        XCTAssertEqual(try accept(request(command: "pi")).get().args, ["--approve"])
        XCTAssertEqual(
            try accept(request(command: "pi", args: ["-na"])).get().args, ["-na"],
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
        XCTAssertEqual(
            Set(SpoolUnattendedPolicy.postures.keys), SpoolPolicy.allowedCommands)
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

    func testThePromptIsReadFromAFileRatherThanTypedOntoTheCommandLine() {
        let accepted = AcceptedSpawnRequest(
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
}
