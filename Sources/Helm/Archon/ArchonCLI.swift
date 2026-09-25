import Foundation

/// Every Archon call helm makes, and every one of them names the workspace it is about.
///
/// **The path is not a convenience parameter — the CLI refuses without it.** `archon` resolves
/// its project from the working directory and exits 1 with *"Not in a git repository"* when that
/// directory is not one. helm's own working directory is whatever launched it (`/` for a `.app`
/// opened from the Dock), so a call that does not say where it is about fails every time,
/// everywhere, for a reason no part of the old code could see.
protocol ArchonClient: Sendable {
    func runs(in workspacePath: WorkspacePath) async throws -> ArchonRunsResponse
    func workflows(in workspacePath: WorkspacePath) async throws -> ArchonWorkflowListResponse
    func run(id: String, in workspacePath: WorkspacePath) async throws -> ArchonRun
    func launch(_ request: ArchonLaunchRequest) async throws -> ArchonLaunchAcknowledgement
    func complete(branch: String, in workspacePath: WorkspacePath) async throws
    func decide(
        _ decision: ArchonGateDecision, text: String?, on runID: String,
        in workspacePath: WorkspacePath
    ) async throws -> ArchonActionAcknowledgement
    func resume(_ run: ArchonRun) async throws -> ArchonLaunchAcknowledgement
}

/// A failed `archon` call, with enough in it to act on.
///
/// **The command is carried rather than described.** The old error was a bare
/// `nonzeroExit(127)`: true, useless, and identical whether Archon was missing, the workspace
/// was not a repo, or the run id was wrong. Every case above is distinguishable from the exit
/// status plus the child's stderr — which was going to `nullDevice`, so helm was discarding the
/// one sentence that says what to do.
struct ArchonCLIError: Error, Equatable, LocalizedError, Sendable {
    /// The invocation as it would be typed, so the operator can run it themselves.
    let command: String
    let reason: Reason

    enum Reason: Equatable, Sendable {
        case launchFailed(String)
        /// `stderr` is bounded — see `ArchonCLI.errorSnippetLimit`.
        case nonzeroExit(status: Int32, stderr: String)
        case timedOut(after: Duration)
        case unreadableOutput(String)
        case emptyOutput
        case actionRejected(String)
        /// `capturedAt` is the temporary file the bytes are still in, deliberately not
        /// deleted: a decode failure is the one outcome where the payload is the evidence.
        case malformedJSON(String, capturedAt: String?)
    }

    var errorDescription: String? {
        "\(detail) (\(command))"
    }

    private var detail: String {
        switch reason {
        case let .launchFailed(reason): "Archon could not be started: \(reason)"
        case let .nonzeroExit(status, stderr):
            stderr.isEmpty
                ? "Archon exited with status \(status)."
                : "Archon exited with status \(status): \(stderr)"
        case let .timedOut(after): "Archon did not answer within \(after)."
        case let .unreadableOutput(reason): "Archon output could not be read: \(reason)"
        case .emptyOutput: "Archon returned no data."
        case let .actionRejected(reason): "Archon refused the action: \(reason)"
        case let .malformedJSON(reason, capturedAt):
            capturedAt.map { "Archon returned malformed data: \(reason) (kept at \($0))" }
                ?? "Archon returned malformed data: \(reason)"
        }
    }
}

/// The sole process and JSON boundary for Archon. The process itself is `Subprocess`'s.
struct ArchonCLI: ArchonClient, Sendable {
    /// **Generous on purpose: this is a deadline, not a latency budget.** A healthy call is
    /// ~0.6s (measured against Archon 0.7.0, `workflow runs`/`get`, warm). Anything past 20s is
    /// hung rather than slow, and the point of the deadline is that a hung call used to strand
    /// `isRefreshing` at true — the rail's spinner spun until helm restarted.
    static let defaultTimeout: Duration = .seconds(20)
    /// How much of the child's stderr rides along in the error. Enough for Archon's four-line
    /// "not a git repository" refusal, short enough that a stack trace cannot become the UI.
    static let errorSnippetLimit = 400

    let inheritedEnvironment: [String: String]
    let homeDirectory: String
    let captureDirectory: URL
    /// Injectable so the deadline can be proven in under a second instead of after twenty.
    let timeout: Duration

    init(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        captureDirectory: URL = FileManager.default.temporaryDirectory,
        timeout: Duration = ArchonCLI.defaultTimeout
    ) {
        self.inheritedEnvironment = inheritedEnvironment
        self.homeDirectory = homeDirectory
        self.captureDirectory = captureDirectory
        self.timeout = timeout
    }

    /// Recent runs for this workspace, plus the per-status totals the rail collapses to one
    /// line each. One command for both, which is why the rail no longer calls `workflow
    /// status`: that one is global, carries no counts, and answers a question the rail stopped
    /// asking.
    ///
    /// The row list is capped by the CLI at 20 whatever is asked; `counts` is over the whole
    /// project, which is why the rail's collapsed lines subtract what is already a line above
    /// them rather than trusting either number alone.
    func runs(in workspacePath: WorkspacePath) async throws -> ArchonRunsResponse {
        try await decode(
            ArchonRunsResponse.self, arguments: ["workflow", "runs", "--json"],
            in: workspacePath.value)
    }

    func workflows(in workspacePath: WorkspacePath) async throws -> ArchonWorkflowListResponse {
        try await decode(
            ArchonWorkflowListResponse.self, arguments: ["workflow", "list", "--json"],
            in: workspacePath.value)
    }

    func run(id: String, in workspacePath: WorkspacePath) async throws -> ArchonRun {
        try await decode(
            ArchonRun.self, arguments: ["workflow", "get", id, "--json", "--verbose"],
            in: workspacePath.value)
    }

    func launch(_ request: ArchonLaunchRequest) async throws -> ArchonLaunchAcknowledgement {
        let arguments =
            ["workflow", "run", request.workflow, request.input, "--detach", "--json"]
            + request.worktree.arguments
        return try await decode(
            ArchonLaunchAcknowledgement.self, arguments: arguments,
            in: request.workspacePath.value)
    }

    func complete(branch: String, in workspacePath: WorkspacePath) async throws {
        let arguments = ["complete", branch]
        let data = try await capture(arguments: arguments, in: workspacePath.value)
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.localizedCaseInsensitiveContains("not found") {
            throw ArchonCLIError(
                command: Self.command(arguments), reason: .actionRejected(text))
        }
    }

    /// Answer one gate. **Recording the decision is all this does** — see `resume(_:)`.
    func decide(
        _ decision: ArchonGateDecision, text: String?, on runID: String,
        in workspacePath: WorkspacePath
    ) async throws -> ArchonActionAcknowledgement {
        try await decode(
            ArchonActionAcknowledgement.self,
            arguments: decision.arguments(for: runID, text: text), in: workspacePath.value)
    }

    /// Actually continue a parked run — **and note which command this is not.**
    ///
    /// `archon workflow resume <id> --json` looks like the answer and is not: it is a
    /// control-plane acknowledgement that reports the run is resumable and then returns
    /// `executed: false`, because executing streams the workflow's output to stdout and would
    /// corrupt the one-line JSON contract. A button wired to it does nothing at all, quietly,
    /// which is the worst kind of control to ship.
    ///
    /// The form that runs is `workflow run <name> <message> --resume --detach --json`, which is
    /// `launch` with one extra flag — so it detaches, and helm gets back the same
    /// acknowledgement it already understands. It is also the same call the CLI's own
    /// interactive `approve` makes after recording an approval.
    ///
    /// **The working directory selects the run, so it is the run's own, not the workspace's.**
    /// `--resume` resolves through `findResumableRun(workflowName, cwd)` — Archon matches a
    /// resumable run by workflow name *and* `working_path` — so invoking from the workspace
    /// root would look for a run that was never there. A run cut into a worktree carries that
    /// worktree in `workingPath`, which is exactly what this passes.
    func resume(_ run: ArchonRun) async throws -> ArchonLaunchAcknowledgement {
        guard let workingPath = run.workingPath, !workingPath.isEmpty else {
            throw ArchonCLIError(
                command: "archon workflow run \(run.workflowName) --resume",
                reason: .launchFailed(
                    "This run has no working path recorded, so there is nowhere to resume it."))
        }
        // The original instruction, not a new one: `--resume` skips the completed nodes and
        // re-enters the workflow, so the run needs the message it was started with.
        let arguments = [
            "workflow", "run", run.workflowName, run.userMessage ?? "", "--resume", "--detach",
            "--json",
        ]
        return try await decode(
            ArchonLaunchAcknowledgement.self, arguments: arguments, in: workingPath)
    }

    /// `~/.bun/bin` ahead of the inherited `PATH`: Archon is installed as a bun global, and a
    /// GUI app inherits launchd's `PATH`, which has never heard of it.
    static func developmentEnvironment(
        inherited: [String: String], homeDirectory: String
    ) -> [String: String] {
        let bun = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".bun/bin").path
        return Subprocess.environment(inherited: inherited, prepending: [bun])
    }

    private func decode<T: Decodable>(
        _ type: T.Type, arguments: [String], in workingDirectory: String
    ) async throws -> T {
        let data = try await capture(arguments: arguments, in: workingDirectory)
        do {
            return try JSONDecoder.archon().decode(type, from: data)
        } catch {
            // The bytes are kept on this branch on purpose. A decode failure means helm's model
            // and Archon's payload have come apart, and the payload is the only thing that
            // says how — this PR shipped a decoder built from an imagined shape and 514 green
            // tests, and there was nothing on disk to check it against. macOS reaps the
            // temporary directory; a stale capture costs nothing and answers everything.
            let kept = captureDirectory.appendingPathComponent(
                "helm-archon-\(UUID().uuidString).json")
            let capturedAt = (try? data.write(to: kept)).map { kept.path }
            throw ArchonCLIError(
                command: Self.command(arguments),
                reason: .malformedJSON(error.localizedDescription, capturedAt: capturedAt))
        }
    }

    /// stdout of one `archon` call that exited 0 with something on it.
    private func capture(arguments: [String], in workingDirectory: String) async throws -> Data {
        let command = Self.command(arguments)
        let result: Subprocess.Result
        do {
            // **The working directory IS the project selector.** `--cwd` exists and would
            // mostly work, but the CLI loads its repo-scoped `.archon/.env` from `process.cwd()`
            // at import time — before it parses argv — so the flag reaches a decision the env
            // has already been made without. Being *in* the directory is what a shell does and
            // what Archon is written against.
            result = try await Subprocess.run(
                ["archon"] + arguments, cwd: workingDirectory,
                environment: Self.developmentEnvironment(
                    inherited: inheritedEnvironment, homeDirectory: homeDirectory),
                timeout: timeout, scratch: captureDirectory)
        } catch let failure as Subprocess.Failure {
            let reason: ArchonCLIError.Reason =
                switch failure {
                case let .captureUnavailable(why): .unreadableOutput(why)
                case let .launchFailed(why): .launchFailed(why)
                case .timedOut: .timedOut(after: timeout)
                case let .unreadableOutput(why): .unreadableOutput(why)
                }
            throw ArchonCLIError(command: command, reason: reason)
        }

        guard result.status == 0 else {
            throw ArchonCLIError(
                command: command,
                reason: .nonzeroExit(
                    status: result.status,
                    stderr: result.stderrSnippet(limit: Self.errorSnippetLimit)))
        }
        guard
            !String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ArchonCLIError(command: command, reason: .emptyOutput)
        }
        return result.stdout
    }

    private static func command(_ arguments: [String]) -> String {
        (["archon"] + arguments).joined(separator: " ")
    }
}
