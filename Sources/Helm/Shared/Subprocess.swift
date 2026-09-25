import Foundation

/// One child process: launched, waited on without holding a thread, and killed by a deadline or
/// by cancelling the task that awaits it.
///
/// Every caller that needs more than a fire-and-forget process goes through this (search for
/// `Subprocess.run`; a list here went stale with the fourth caller). Each maps `Failure` onto its
/// own error type, or onto nil where any failure means "no answer", because only the caller knows
/// what the command was for.
///
/// **Waiting holds no thread.** The wait is `Process.terminationHandler`, which Foundation calls
/// when the child exits. The two runners this replaced blocked in `waitUntilExit()`, one on a
/// dispatch thread and one inside `Task.detached` — and the second parked a thread of Swift's
/// cooperative pool, which has one per core, for the life of every `git` child (#377;
/// `WorktreeCLITests.testWaitingOnChildrenHoldsNoThreadOfTheCooperativePool`).
///
/// **stdout and stderr go to regular files, not `Pipe`s.** A pipe nobody drains fills its
/// kernel buffer (64 KiB on macOS) and blocks the child, and `workflow get --verbose` on a large
/// Archon run has no ceiling. A file has no limit and no reader to schedule.
enum Subprocess {
    struct Result: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        /// stderr, trimmed and cut to `limit` characters plus an ellipsis — enough for a tool's
        /// own refusal, short enough that a stack trace cannot become the UI.
        func stderrSnippet(limit: Int) -> String {
            let trimmed = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > limit else { return trimmed }
            return String(trimmed.prefix(limit)) + "…"
        }
    }

    /// Everything but a nonzero exit, which is a `Result` — only the caller knows whether a
    /// status is a failure (`git merge-base --is-ancestor` answers with one). Cancellation throws
    /// `CancellationError`.
    enum Failure: Error, Equatable {
        /// The capture files could not be created in `scratch` (nil), or not opened (why).
        /// Nil lets each caller keep its own sentence for the first case.
        case captureUnavailable(String?)
        /// `Process.run()` refused: no `/usr/bin/env`, an unreadable working directory.
        case launchFailed(String)
        /// The deadline passed and the child was sent SIGTERM.
        case timedOut
        /// The child exited but its captured output could not be read back.
        case unreadableOutput(String)
    }

    /// Run `/usr/bin/env <arguments>`.
    ///
    /// - Parameters:
    ///   - cwd: the child's working directory, or nil to inherit helm's — which is `/` for a
    ///     `.app` opened from the Dock, so a tool that resolves a project from its cwd must be
    ///     given one.
    ///   - scratch: where the capture files live for the length of the call. They are removed
    ///     on every path.
    static func run(
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String],
        timeout: Duration,
        scratch: URL = FileManager.default.temporaryDirectory
    ) async throws -> Result {
        let outputURL = scratch.appendingPathComponent("helm-subprocess-\(UUID().uuidString).out")
        let errorURL = scratch.appendingPathComponent("helm-subprocess-\(UUID().uuidString).err")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        else { throw Failure.captureUnavailable(nil) }

        let output: FileHandle
        let errors: FileHandle
        do {
            output = try FileHandle(forWritingTo: outputURL)
            errors = try FileHandle(forWritingTo: errorURL)
        } catch {
            throw Failure.captureUnavailable(error.localizedDescription)
        }
        // The child dup'd its own descriptors at exec, so helm's copies are only closed here.
        defer {
            try? output.close()
            try? errors.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        let child = Child(process)
        try await child.run(timeout: timeout)
        if child.didTimeOut { throw Failure.timedOut }

        do {
            return Result(
                status: process.terminationStatus,
                stdout: try Data(contentsOf: outputURL),
                stderr: try Data(contentsOf: errorURL))
        } catch {
            throw Failure.unreadableOutput(error.localizedDescription)
        }
    }

    /// `inherited`, with `directories` ahead of its `PATH`. A GUI app inherits launchd's `PATH`,
    /// which has never heard of a bun global or a Homebrew install. An empty inherited `PATH`
    /// leaves no trailing colon.
    static func environment(
        inherited: [String: String], prepending directories: [String]
    ) -> [String: String] {
        var environment = inherited
        let inheritedPath = inherited["PATH"].flatMap { $0.isEmpty ? nil : $0 }
        environment["PATH"] = (directories + [inheritedPath].compactMap { $0 })
            .joined(separator: ":")
        return environment
    }

    /// The launched process and the three things that can end the wait on it.
    ///
    /// `@unchecked Sendable` because `Process` is not `Sendable`, and this has to be reachable
    /// from the deadline task and from a cancellation handler on whichever thread cancelled.
    /// Everything mutable it adds is behind the lock.
    private final class Child: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var timedOut = false
        private var launched = false
        private var terminateRequested = false

        init(_ process: Process) { self.process = process }

        var didTimeOut: Bool { lock.withLock { timedOut } }

        /// Returns when the child exits. Throws `Failure.launchFailed` if it never started and
        /// `CancellationError` if the awaiting task was cancelled; a deadline kill returns
        /// normally with `didTimeOut` set.
        func run(timeout: Duration) async throws {
            try await withTaskCancellationHandler {
                let watchdog = Task {
                    try await Task.sleep(for: timeout)
                    lock.withLock { timedOut = true }
                    terminate()
                }
                defer { watchdog.cancel() }
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    // Set before `run()`, so an instant exit cannot slip past it.
                    process.terminationHandler = { _ in continuation.resume() }
                    do {
                        try process.run()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(
                            throwing: Failure.launchFailed(error.localizedDescription))
                        return
                    }
                    markLaunched()
                }
                try Task.checkCancellation()
            } onCancel: {
                terminate()
            }
        }

        /// A cancellation that arrives before the child exists has nothing to signal, so it is
        /// remembered and honoured here. Without this the child would outlive the call that
        /// asked for it.
        private func markLaunched() {
            let owed = lock.withLock {
                launched = true
                return terminateRequested
            }
            if owed { signal() }
        }

        private func terminate() {
            let started = lock.withLock {
                terminateRequested = true
                return launched
            }
            if started { signal() }
        }

        /// SIGTERM, and only while the child is alive: `Process.terminate()` raises an
        /// Objective-C exception on a process that was never launched, and Swift cannot catch
        /// that.
        private func signal() {
            guard process.isRunning else { return }
            process.terminate()
        }
    }
}
