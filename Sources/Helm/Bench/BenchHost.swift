import Foundation
import HelmWire

/// benchd's machine, as the Worktrees drawer, the Archon drawer and the workspace tabs' branch
/// labels see it (M5c, #459): its `git`, its `archon`, its disk. **helm runs neither program and
/// reads no repository itself**, on one machine as much as when benchd is on another: the
/// repositories are wherever benchd is, and helm only draws.
///
/// Every line of git and Archon logic stays in helm (`WorktreeCLI`, `ArchonCLI`) and only the
/// process moves, so what a delete checks and in which order is exactly what it was. What this
/// seam owes its callers is fidelity: a command's exit status and output as the program gave
/// them, and "could not ask" never passed off as "not there" or "nothing to lose".
///
/// A protocol so a test can run the commands on its own machine (`LocalBenchHost`) without a
/// benchd.
protocol BenchHost: Sendable {
    /// Run one command there. A nonzero exit is a `Result`, as `Subprocess.run` answers; benchd
    /// refusing (no such directory, the program not installed) or not being reachable is
    /// `Subprocess.Failure.launchFailed` with the reason, and a command past `timeout` is
    /// `.timedOut`. Cancelling the task stops waiting and throws `CancellationError`; the command
    /// itself runs on to its end on benchd, so a cancelled `git worktree remove` may still have
    /// removed the worktree, and the caller's next read is what says so. An answer lost after the
    /// request went out says the command may have run.
    func run(_ command: BenchCommand, timeout: Duration) async throws -> Subprocess.Result
    /// Which of these absolute paths exist there. Throws when benchd could not look.
    func existing(_ paths: [String]) async throws -> Set<String>
    /// Every repository under benchd's home, the workspaces' first (the Worktrees drawer's list).
    func repositories(workspaces: [String]) async throws -> [BenchGitRepository]
}

/// Why benchd could not answer a `BenchHost` question: not reached, refused, or an answer this
/// build cannot read. The words are for the drawer's failure line.
struct BenchHostFailure: Error, LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// `BenchHost` through benchd's verbs (`command/run`, `path/exists`, `git/repositories`).
///
/// **Waiting holds no thread of Swift's cooperative pool.** A command can run for its whole
/// deadline (two minutes for `archon complete`) and the drawer reads six repositories at once, so
/// each blocking socket wait gets a thread of its own, the reason `Subprocess` waits on a
/// termination handler (#377).
struct BenchdHost: BenchHost {
    /// nil when there is no benchd to ask (a root benchd would refuse); every call then fails.
    let endpoint: BenchEndpoint?

    /// How much longer than a command's own deadline helm waits for benchd's answer: benchd kills
    /// the command at its deadline and answers `timed_out`, so helm's wait only has to cover that.
    static let answerMargin: Duration = .seconds(5)
    /// The wait for `path/exists` and `git/repositories`: a disk read on benchd's side.
    static let lookTimeout: Duration = .seconds(20)

    @MainActor
    init(client: BenchClient) {
        endpoint = client.endpoint
    }

    init(endpoint: BenchEndpoint?) {
        self.endpoint = endpoint
    }

    func run(_ command: BenchCommand, timeout: Duration) async throws -> Subprocess.Result {
        let request = BenchCommandRunRequest(
            id: Self.id(), command: command,
            timeoutMs: UInt64(max(0, (timeout / .milliseconds(1)).rounded())))
        let answer: BenchCommandRun
        do {
            answer = try await ask(
                request, answering: BenchCommandRun.self, within: timeout + Self.answerMargin)
        } catch let failure as BenchHostFailure {
            throw Subprocess.Failure.launchFailed(failure.reason)
        }
        switch answer {
        case let .exited(status, stdout, stderr):
            return Subprocess.Result(status: status, stdout: stdout, stderr: stderr)
        case .timedOut:
            throw Subprocess.Failure.timedOut
        }
    }

    /// Asked a slice at a time: a verb's request line is capped at 64 KB, and a repository with
    /// hundreds of worktrees would pass it in one.
    static let pathsPerRequest = 200

    func existing(_ paths: [String]) async throws -> Set<String> {
        var found: Set<String> = []
        for start in stride(from: 0, to: paths.count, by: Self.pathsPerRequest) {
            let slice = Array(paths[start..<min(start + Self.pathsPerRequest, paths.count)])
            let answer = try await ask(
                BenchPathExistsRequest(id: Self.id(), paths: slice),
                answering: BenchPathExists.self, within: Self.lookTimeout)
            found.formUnion(answer.existing)
        }
        return found
    }

    func repositories(workspaces: [String]) async throws -> [BenchGitRepository] {
        try await ask(
            BenchGitRepositoriesRequest(id: Self.id(), workspaces: workspaces),
            answering: BenchGitRepositories.self, within: Self.lookTimeout
        ).repositories
    }

    /// One verb on a connection and a thread of its own. Every failure is a `BenchHostFailure`
    /// naming it, except cancellation, which closes the connection and is `CancellationError`.
    private func ask<Payload: Decodable & Sendable>(
        _ request: some Encodable & Sendable, answering _: Payload.Type, within timeout: Duration
    ) async throws -> Payload {
        guard let endpoint else { throw BenchHostFailure(reason: "there is no benchd to ask") }
        let connection = PendingConnection()
        let seconds = timeout / .seconds(1)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    continuation.resume(
                        with: Self.exchange(
                            request, at: endpoint, within: seconds, connection: connection,
                            answering: Payload.self))
                }
                thread.name = "helm.bench-host"
                thread.start()
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func exchange<Payload: Decodable & Sendable>(
        _ request: some Encodable, at endpoint: BenchEndpoint, within seconds: TimeInterval,
        connection: PendingConnection, answering _: Payload.Type
    ) -> Result<Payload, any Error> {
        do {
            let socket = try BenchSocket(endpoint: endpoint, timeout: seconds)
            // Released before it is closed, so a late cancel never shuts down a reused descriptor.
            defer {
                connection.release()
                socket.close()
            }
            guard connection.hold(socket) else { return .failure(CancellationError()) }
            try socket.writeLine(JSONEncoder().encode(request))
            let line: Data?
            do {
                line = try socket.readLine()
            } catch {
                if connection.isCancelled { return .failure(CancellationError()) }
                return .failure(Self.lost(error))
            }
            guard let line else {
                if connection.isCancelled { return .failure(CancellationError()) }
                return .failure(Self.lost("benchd closed the connection"))
            }
            let answer = try JSONDecoder().decode(BenchResponse<Payload>.self, from: line)
            guard answer.status == .ok, let data = answer.data else {
                return .failure(
                    BenchHostFailure(reason: answer.reason ?? "benchd refused without a reason"))
            }
            return .success(data)
        } catch {
            if connection.isCancelled { return .failure(CancellationError()) }
            return .failure(BenchHostFailure(reason: String(describing: error)))
        }
    }

    /// benchd had the request and no answer came back: whatever was asked may have happened.
    private static func lost(_ why: Any) -> BenchHostFailure {
        BenchHostFailure(reason: "no answer from benchd, so it may have run anyway: \(why)")
    }

    private static func id() -> String { "helm-host-\(UUID().uuidString)" }
}

/// The socket one `ask` is waiting on, so cancelling the task can wake the thread reading it.
private final class PendingConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: BenchSocket?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Keeps `socket` to interrupt; false when the task was already cancelled.
    func hold(_ socket: BenchSocket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.socket = socket
        return true
    }

    func release() {
        lock.lock()
        socket = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        socket?.interrupt()
        lock.unlock()
    }
}
