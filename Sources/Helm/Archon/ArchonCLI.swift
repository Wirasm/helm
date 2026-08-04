import Foundation

/// Every Archon call helm makes, and every one of them names the workspace it is about.
///
/// **The path is not a convenience parameter — the CLI refuses without it.** `archon` resolves
/// its project from the working directory and exits 1 with *"Not in a git repository"* when that
/// directory is not one. helm's own working directory is whatever launched it (`/` for a `.app`
/// opened from the Dock), so a call that does not say where it is about fails every time,
/// everywhere, for a reason no part of the old code could see.
protocol ArchonClient: Sendable {
    func runs(in workspacePath: String) async throws -> ArchonRunsResponse
    func workflows(in workspacePath: String) async throws -> ArchonWorkflowListResponse
    func run(id: String, in workspacePath: String) async throws -> ArchonRun
    func launch(_ request: ArchonLaunchRequest) async throws -> ArchonLaunchAcknowledgement
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
        case let .malformedJSON(reason, capturedAt):
            capturedAt.map { "Archon returned malformed data: \(reason) (kept at \($0))" }
                ?? "Archon returned malformed data: \(reason)"
        }
    }
}

/// The sole process and JSON boundary for Archon.
///
/// **stdout goes to a regular file rather than a `Pipe`, and the reason is the mechanism, not a
/// measurement.** A `Pipe` a process is not draining fills its kernel buffer (64 KiB on macOS)
/// and blocks the child; `waitUntilExit()` before reading is therefore a deadlock waiting for a
/// payload that outgrows the buffer, and `workflow get --verbose` on a 27-node run is 7 KiB
/// today with no ceiling. A file has no such limit and no reader to schedule. **stderr is a
/// second file** — small by nature, and the only place Archon says *why* it refused.
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
    func runs(in workspacePath: String) async throws -> ArchonRunsResponse {
        try await decode(
            ArchonRunsResponse.self, arguments: ["workflow", "runs", "--json"],
            in: workspacePath)
    }

    func workflows(in workspacePath: String) async throws -> ArchonWorkflowListResponse {
        try await decode(
            ArchonWorkflowListResponse.self, arguments: ["workflow", "list", "--json"],
            in: workspacePath)
    }

    func run(id: String, in workspacePath: String) async throws -> ArchonRun {
        try await decode(
            ArchonRun.self, arguments: ["workflow", "get", id, "--json", "--verbose"],
            in: workspacePath)
    }

    func launch(_ request: ArchonLaunchRequest) async throws -> ArchonLaunchAcknowledgement {
        let arguments =
            ["workflow", "run", request.workflow, request.input, "--detach", "--json"]
            + request.worktree.arguments
        return try await decode(
            ArchonLaunchAcknowledgement.self, arguments: arguments, in: request.workspacePath)
    }

    /// `~/.bun/bin` ahead of the inherited `PATH`: Archon is installed as a bun global, and a
    /// GUI app inherits launchd's `PATH`, which has never heard of it.
    static func developmentEnvironment(
        inherited: [String: String], homeDirectory: String
    ) -> [String: String] {
        var environment = inherited
        let developmentBin = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".bun/bin").path
        let inheritedPath = inherited["PATH"].flatMap { $0.isEmpty ? nil : $0 }
        environment["PATH"] = [developmentBin, inheritedPath].compactMap { $0 }.joined(
            separator: ":")
        return environment
    }

    private func decode<T: Decodable>(
        _ type: T.Type, arguments: [String], in workingDirectory: String
    ) async throws -> T {
        let capture = try await capture(arguments: arguments, in: workingDirectory)
        do {
            let value = try JSONDecoder.archon().decode(type, from: capture.data)
            try? FileManager.default.removeItem(at: capture.url)
            return value
        } catch {
            // The file survives this branch on purpose. A decode failure means helm's model
            // and Archon's payload have come apart, and the payload is the only thing that
            // says how — this PR shipped a decoder built from an imagined shape and 514 green
            // tests, and there was nothing on disk to check it against. macOS reaps the
            // temporary directory; a stale capture costs nothing and answers everything.
            throw ArchonCLIError(
                command: Self.command(arguments),
                reason: .malformedJSON(error.localizedDescription, capturedAt: capture.url.path))
        }
    }

    private struct Capture {
        let data: Data
        let url: URL
    }

    private func capture(arguments: [String], in workingDirectory: String) async throws -> Capture {
        let command = Self.command(arguments)
        let outputURL = captureDirectory.appendingPathComponent(
            "helm-archon-\(UUID().uuidString).json")
        let errorURL = captureDirectory.appendingPathComponent(
            "helm-archon-\(UUID().uuidString).err")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        else {
            throw ArchonCLIError(
                command: command, reason: .unreadableOutput("could not create temporary capture"))
        }
        // stderr is only ever read on a failure path, so it is dropped here unconditionally.
        // stdout is dropped by every path except the malformed-JSON one above.
        defer { try? FileManager.default.removeItem(at: errorURL) }

        let output: FileHandle
        let errors: FileHandle
        do {
            output = try FileHandle(forWritingTo: outputURL)
            errors = try FileHandle(forWritingTo: errorURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw ArchonCLIError(
                command: command, reason: .unreadableOutput(error.localizedDescription))
        }
        // Closed after the wait rather than after `run()`. The child dup'd its own descriptors
        // at exec, so helm's copies are dead weight either way — but `run()` now happens on the
        // child's own thread, so "after run" is no longer a point this function can name.
        defer {
            try? output.close()
            try? errors.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["archon"] + arguments
        process.environment = Self.developmentEnvironment(
            inherited: inheritedEnvironment, homeDirectory: homeDirectory)
        // **The working directory IS the project selector.** `--cwd` exists and would mostly
        // work, but the CLI loads its repo-scoped `.archon/.env` from `process.cwd()` at import
        // time — before it parses argv — so the flag reaches a decision the env has already
        // been made without. Being *in* the directory is what a shell does and what Archon is
        // written against.
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        let child = ArchonChild(process)
        do {
            try await child.run(timeout: timeout)
        } catch let failure as ArchonChild.LaunchFailure {
            try? FileManager.default.removeItem(at: outputURL)
            throw ArchonCLIError(
                command: command, reason: .launchFailed(failure.underlying.localizedDescription))
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        guard !child.didTimeOut else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ArchonCLIError(command: command, reason: .timedOut(after: timeout))
        }

        guard child.terminationStatus == 0 else {
            let stderr = Self.snippet(of: errorURL)
            try? FileManager.default.removeItem(at: outputURL)
            throw ArchonCLIError(
                command: command,
                reason: .nonzeroExit(status: child.terminationStatus, stderr: stderr))
        }

        let data: Data
        do {
            data = try Data(contentsOf: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw ArchonCLIError(
                command: command, reason: .unreadableOutput(error.localizedDescription))
        }
        guard !data.isEmpty,
            !String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ArchonCLIError(command: command, reason: .emptyOutput)
        }
        return Capture(data: data, url: outputURL)
    }

    private static func command(_ arguments: [String]) -> String {
        (["archon"] + arguments).joined(separator: " ")
    }

    private static func snippet(of url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > errorSnippetLimit else { return trimmed }
        return String(trimmed.prefix(errorSnippetLimit)) + "…"
    }
}

/// One `archon` invocation: launched, waited on without holding a cooperative thread, and
/// killable from outside.
///
/// **It exists because `Task.detached { process.waitUntilExit() }` cannot be interrupted.**
/// Detached work is unstructured, so cancelling a poll never unwound it: one hung call left
/// `isRefreshing` true for the life of the process, and closing a pane orphaned the child. A
/// blocked `waitUntilExit()` can only be unblocked by killing what it waits on, which is what
/// both the deadline and the cancellation handler do.
///
/// **`run()` and `waitUntilExit()` happen on the SAME thread, and that is not a style choice.**
/// `NSConcreteTask.waitUntilExit` spins the *calling thread's* run loop for a termination
/// source the launch installed, so waiting from a different thread than the one that launched
/// hangs forever — with the child already reaped and nothing to see in `ps`. Measured: the
/// suite sat in `mach_msg2_trap` inside `waitUntilExit` for 10 minutes against a dead child.
///
/// `@unchecked Sendable` because `Process` is not `Sendable` and this has to be reachable from
/// a cancellation handler running on whichever thread cancelled. Everything mutable it adds is
/// two `Bool`s behind a lock.
private final class ArchonChild: @unchecked Sendable {
    /// `Process.run()` refusing — a missing `/usr/bin/env`, an unreadable working directory.
    /// Wrapped rather than thrown as an `ArchonCLIError` because this type does not know which
    /// command it is running, and the error is worth nothing without that.
    struct LaunchFailure: Error {
        let underlying: any Error
    }

    private let process: Process
    private let lock = NSLock()
    private var timedOut = false
    private var launched = false
    private var terminateRequested = false

    init(_ process: Process) { self.process = process }

    var terminationStatus: Int32 { process.terminationStatus }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    /// Returns when the child exits. Throws `LaunchFailure` if it never started and
    /// `CancellationError` if the awaiting task was cancelled; sets `didTimeOut` and returns
    /// normally when the deadline killed it, because naming the command in that error is the
    /// caller's job.
    func run(timeout: Duration) async throws {
        try await withTaskCancellationHandler {
            let watchdog = Task {
                try await Task.sleep(for: timeout)
                markTimedOut()
                terminate()
            }
            defer { watchdog.cancel() }
            // A dispatch thread rather than the cooperative pool: `waitUntilExit()` blocks its
            // thread for the whole call, and Swift's pool has one thread per core to lose.
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: LaunchFailure(underlying: error))
                        return
                    }
                    markLaunched()
                    process.waitUntilExit()
                    continuation.resume()
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            terminate()
        }
    }

    private func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    /// A cancellation that arrives in the window between `run(timeout:)` being awaited and the
    /// child actually existing has nothing to signal, so it is remembered and honoured here.
    /// Without this the child would outlive the call that asked for it — the exact orphaning
    /// the deadline and the handler exist to prevent, just half a millisecond earlier.
    private func markLaunched() {
        lock.lock()
        launched = true
        let owed = terminateRequested
        lock.unlock()
        if owed { signal() }
    }

    private func terminate() {
        lock.lock()
        terminateRequested = true
        let started = launched
        lock.unlock()
        guard started else { return }
        signal()
    }

    /// SIGTERM, and only while the child is alive: `Process.terminate()` raises an
    /// Objective-C exception on a process that was never launched, and Swift cannot catch
    /// that — it is a crash, not an error.
    private func signal() {
        guard process.isRunning else { return }
        process.terminate()
    }
}
