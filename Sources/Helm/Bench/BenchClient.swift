import Foundation
import HelmWire

/// helm as benchd's client (M4 PR 3c of #354): a request per verb, and one long `events
/// --follow` connection that carries the document back.
///
/// **Two connections, because benchd has two shapes.** A verb is one line out and one line
/// back on a connection of its own (the daemon's framing). The follower keeps one connection
/// open: its first line is the whole document, then a frame per event, each changed document
/// in full. helm renders only from what the follower delivers, so an agent's verb and the
/// operator's key reach the screen by the same road.
///
/// **The follower reconnects on its own**, with a capped backoff, and its first line after a
/// reconnect is the whole document again — so a benchd restart, or a follower benchd dropped for
/// falling behind, costs a redraw and nothing else. While it is down `state` says so, and the
/// last document stays on screen.
@MainActor
final class BenchClient: ObservableObject {
    enum State: Equatable {
        case connecting
        case connected
        /// Why, with the socket named, for the status bar.
        case disconnected(String)
    }

    @Published private(set) var state: State = .connecting

    /// The socket this client speaks to: `<bench root>/benchd.sock`.
    let socketPath: String

    /// Each document the follower delivers, on the main actor, in order. The first after a
    /// (re)connect is the whole state and is always delivered; after that only a newer seq is.
    var onDocument: ((DocumentAt) -> Void)?

    private let latest = LatestDocument()
    private var follower: BenchFollower?
    private var delivered: UInt64?

    /// How long a verb may wait for its answer. benchd answers in milliseconds; this is the
    /// ceiling on a daemon that has stopped answering, so a key does not hang the window.
    nonisolated static let requestTimeout: TimeInterval = 2

    /// Set when there is no socket to try at all — a bench root benchd would refuse. Then the
    /// client never connects, and says why for as long as it lives.
    private let refused: String?

    init(socketPath: String) {
        self.socketPath = socketPath
        refused = nil
    }

    init(unreachable why: String) {
        socketPath = ""
        refused = why
        state = .disconnected(why)
    }

    /// The client for this helm's bench root (`BenchRoot`), or why there is none.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<BenchClient, BenchRootError> {
        BenchRoot.resolve(environment: environment).map {
            BenchClient(socketPath: $0.appendingPathComponent("benchd.sock").path)
        }
    }

    func start() {
        guard follower == nil, refused == nil else { return }
        let follower = BenchFollower(path: socketPath, latest: latest) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(event) }
            }
        }
        self.follower = follower
        follower.start()
    }

    func stop() {
        follower?.stop()
        follower = nil
    }

    private func receive(_ event: BenchFollower.Event) {
        switch event {
        case .connected(let at):
            state = .connected
            delivered = at.seq
            onDocument?(at)
        case .frame(let at):
            if let delivered, at.seq <= delivered { return }
            delivered = at.seq
            onDocument?(at)
        case .disconnected(let why):
            state = .disconnected(why)
        }
    }

    /// One verb, one answer. Blocking, and bounded by `requestTimeout`.
    nonisolated func request<Payload: Decodable & Sendable>(
        _ request: some Encodable, answering _: Payload.Type = Payload.self
    ) throws -> BenchResponse<Payload> {
        if let refused { throw BenchSocket.Failure(description: refused) }
        let socket = try BenchSocket(path: socketPath, timeout: Self.requestTimeout)
        defer { socket.close() }
        try socket.writeLine(JSONEncoder().encode(request))
        guard let line = try socket.readLine() else {
            throw BenchSocket.Failure(description: "benchd closed the connection without answering")
        }
        return try JSONDecoder().decode(BenchResponse<Payload>.self, from: line)
    }

    /// The document at `seq` or later, as soon as the follower has it — for a caller that sent a
    /// verb and must read what it did before returning (the spool reports it). benchd hands the
    /// frame to its followers before it answers, so this is normally already here. nil when the
    /// follower is down or slower than `within`.
    ///
    /// It also delivers that document now, so the bench a caller reads next is the one its verb
    /// made; the follower's own delivery of it is then a no-op.
    func document(atLeast seq: UInt64, within timeout: TimeInterval) -> DocumentAt? {
        guard let at = latest.wait(atLeast: seq, until: Date().addingTimeInterval(timeout))
        else { return nil }
        receive(.frame(at))
        return at
    }
}

/// The newest document the follower has read, shared between its thread and the main actor.
final class LatestDocument: @unchecked Sendable {
    private let condition = NSCondition()
    private var current: DocumentAt?

    func store(_ at: DocumentAt, replacing: Bool) {
        condition.lock()
        if replacing || current.map({ at.seq > $0.seq }) ?? true { current = at }
        condition.broadcast()
        condition.unlock()
    }

    func wait(atLeast seq: UInt64, until deadline: Date) -> DocumentAt? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let current, current.seq >= seq { return current }
            guard condition.wait(until: deadline) else { return nil }
        }
    }
}

/// The follower's thread: connect, ask to follow, read the document, then frames; on any failure
/// say so and try again after a capped backoff. It never touches the main actor itself — it
/// reports through `emit`.
final class BenchFollower: @unchecked Sendable {
    enum Event: Sendable {
        case connected(DocumentAt)
        case frame(DocumentAt)
        case disconnected(String)
    }

    /// The waits between reconnects: short enough that a benchd restart is a blink, capped so a
    /// benchd that is gone for good costs one attempt every few seconds.
    static let backoff: [TimeInterval] = [0.1, 0.25, 0.5, 1, 2, 4]

    private let path: String
    private let latest: LatestDocument
    private let emit: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var socket: BenchSocket?

    init(path: String, latest: LatestDocument, emit: @escaping @Sendable (Event) -> Void) {
        self.path = path
        self.latest = latest
        self.emit = emit
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "helm.bench-follower"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        socket?.interrupt()
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        var attempt = 0
        while !isStopped {
            let why = follow { attempt = 0 }
            guard !isStopped else { return }
            emit(.disconnected(why))
            Thread.sleep(forTimeInterval: Self.backoff[min(attempt, Self.backoff.count - 1)])
            attempt += 1
        }
    }

    /// One connection's life. Answers why it ended.
    private func follow(onConnected: () -> Void) -> String {
        let socket: BenchSocket
        do {
            socket = try BenchSocket(path: path, timeout: nil)
        } catch {
            return "\(error)"
        }
        lock.lock()
        if stopped {
            lock.unlock()
            return "stopped"
        }
        self.socket = socket
        lock.unlock()
        defer {
            lock.lock()
            self.socket = nil
            lock.unlock()
            socket.close()
        }
        let decoder = JSONDecoder()
        do {
            try socket.writeLine(
                JSONEncoder().encode(BenchFollowRequest(id: "helm-follow-\(UUID().uuidString)")))
            guard let first = try socket.readLine() else {
                return "benchd closed the connection at \(path)"
            }
            let answer = try decoder.decode(BenchResponse<DocumentAt>.self, from: first)
            guard answer.status == .ok, let at = answer.data else {
                return "benchd refused to be followed: \(answer.reason ?? "no reason given")"
            }
            onConnected()
            latest.store(at, replacing: true)
            emit(.connected(at))
            while let line = try socket.readLine() {
                let frame = try decoder.decode(BenchFrame.self, from: line)
                guard let document = frame.document else { continue }
                let at = DocumentAt(seq: frame.event.seq, document: document)
                latest.store(at, replacing: false)
                emit(.frame(at))
            }
            return "benchd closed the connection at \(path)"
        } catch {
            return "\(error)"
        }
    }
}
