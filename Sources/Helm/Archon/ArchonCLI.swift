import Foundation
import HelmWire

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
    func status(in workspacePath: WorkspacePath) async throws -> ArchonStatusResponse
    func attention(in workspacePath: WorkspacePath) async throws -> ArchonAttentionResponse
    func launch(_ request: ArchonLaunchRequest) async throws -> ArchonLaunchAcknowledgement
    func answer(
        _ answer: ArchonAnswer, text: String?, in workspacePath: WorkspacePath
    ) async throws -> ArchonActionAcknowledgement
    func resume(
        runID: String, in workspacePath: WorkspacePath
    ) async throws -> ArchonActionAcknowledgement
    func cancel(
        runID: String, in workspacePath: WorkspacePath
    ) async throws
        -> ArchonActionAcknowledgement
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

/// The sole process and JSON boundary for Archon. The process runs on benchd's machine
/// (`BenchHost`, M5c), where the workspace and Archon's home are, whether that is this Mac or
/// another; everything about what the output means stays here.
struct ArchonCLI: ArchonClient, Sendable {
    /// **Generous on purpose: this is a deadline, not a latency budget.** A healthy call is
    /// ~0.6s (measured against Archon 0.7.0, `workflow runs`/`get`, warm). Anything past 20s is
    /// hung rather than slow, and the point of the deadline is that a hung call used to strand
    /// `isRefreshing` at true — the rail's spinner spun until helm restarted.
    static let defaultTimeout: Duration = .seconds(20)
    /// How much of the child's stderr rides along in the error. Enough for Archon's four-line
    /// "not a git repository" refusal, short enough that a stack trace cannot become the UI.
    static let errorSnippetLimit = 400

    let host: any BenchHost
    /// Where a payload helm could not decode is kept, on helm's side: it is helm's evidence.
    let captureDirectory: URL
    /// Injectable so the deadline can be proven in under a second instead of after twenty.
    let timeout: Duration

    init(
        host: any BenchHost,
        captureDirectory: URL = FileManager.default.temporaryDirectory,
        timeout: Duration = ArchonCLI.defaultTimeout
    ) {
        self.host = host
        self.captureDirectory = captureDirectory
        self.timeout = timeout
    }

    /// The newest runs of this workspace's project, every status, capped by the CLI at 20. Each
    /// carries its stage list (`terminal_graph`) and the nodes it is in (`active_nodes`), which
    /// is what the drawer's rows and dots are drawn from. `counts` is decoded and not read.
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

    /// The running and paused runs of this workspace's project, each with the per-node fold of
    /// its events (`nodes`): which stages completed, failed or were skipped. One call for every
    /// live run, so a refresh costs the same with one run as with ten.
    func status(in workspacePath: WorkspacePath) async throws -> ArchonStatusResponse {
        try await decode(
            ArchonStatusResponse.self, arguments: ["workflow", "status", "--json", "--verbose"],
            in: workspacePath.value)
    }

    /// Stop a running run. `ok` is the contract, as for every `--json` verb.
    func cancel(
        runID: String, in workspacePath: WorkspacePath
    ) async throws
        -> ArchonActionAcknowledgement
    {
        try await decode(
            ArchonActionAcknowledgement.self,
            arguments: ["workflow", "cancel", runID, "--json"], in: workspacePath.value)
    }

    func launch(_ request: ArchonLaunchRequest) async throws -> ArchonLaunchAcknowledgement {
        let arguments =
            ["workflow", "run", request.workflow, request.input, "--detach", "--json"]
            + request.worktree.arguments
        return try await decode(
            ArchonLaunchAcknowledgement.self, arguments: arguments,
            in: request.workspacePath.value)
    }

    /// The attention queue of this workspace's project.
    func attention(in workspacePath: WorkspacePath) async throws -> ArchonAttentionResponse {
        try await decode(
            ArchonAttentionResponse.self, arguments: ["workflow", "attention", "--json"],
            in: workspacePath.value)
    }

    /// Answer one queue item; the detached child Archon spawns continues the run.
    func answer(
        _ answer: ArchonAnswer, text: String?, in workspacePath: WorkspacePath
    ) async throws -> ArchonActionAcknowledgement {
        try await decode(
            ArchonActionAcknowledgement.self, arguments: answer.arguments(text: text),
            in: workspacePath.value)
    }

    /// Continue a failed or paused run from its completed nodes, in a detached child. A full
    /// run id resolves from any directory.
    func resume(
        runID: String, in workspacePath: WorkspacePath
    ) async throws -> ArchonActionAcknowledgement {
        try await decode(
            ArchonActionAcknowledgement.self,
            arguments: ["workflow", "resume", runID, "--detach", "--json"],
            in: workspacePath.value)
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
            result = try await host.run(
                .archon(args: arguments, cwd: workingDirectory), timeout: timeout)
        } catch let failure as Subprocess.Failure {
            let reason: ArchonCLIError.Reason =
                switch failure {
                case let .captureUnavailable(why):
                    .unreadableOutput(why ?? "could not create temporary capture")
                case let .launchFailed(why): .launchFailed(why)
                case .timedOut: .timedOut(after: timeout)
                case let .unreadableOutput(why): .unreadableOutput(why)
                }
            throw ArchonCLIError(command: command, reason: reason)
        }

        guard result.status == 0 else {
            // A refused control verb exits 1 with its reason on stdout, while stderr carries
            // Archon's start-up chatter ("stripped 22 keys from .env"). The reason is the
            // sentence worth showing.
            if let refusal = try? JSONDecoder().decode(
                ArchonActionAcknowledgement.self, from: result.stdout),
                !refusal.ok, let reason = refusal.error
            {
                throw ArchonCLIError(command: command, reason: .actionRejected(reason))
            }
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

    /// The invocation as an error names it. An answer's text is elided: the operator just
    /// typed it, and a paragraph of it would bury the reason in the red line.
    private static func command(_ arguments: [String]) -> String {
        var shown = arguments
        if let flag = shown.firstIndex(of: "--text"), shown.indices.contains(flag + 1) {
            shown[flag + 1] = "…"
        }
        return (["archon"] + shown).joined(separator: " ")
    }
}
