import BenchKit
import Foundation
import HelmWire

/// One Chrome DevTools Protocol connection: numbered calls with typed replies, and events.
///
/// **Only what the pane needs.** CDP is a large protocol, and agents already have a complete
/// client for it (Playwright). The pane speaks the few methods that show a tab and forward
/// the operator's hands — and nothing here is meant to grow into browser automation.
///
/// **Through benchd, never to the browser directly** (M5c, #459). The browser runs on benchd's
/// machine, which may not be this one, so this sends `browser/connect` and benchd relays the
/// messages on that same connection, one JSON object per line each way. helm dials no port but
/// benchd's own, on one machine as much as across two.
///
/// Sessions are *flat* (`Target.attachToTarget { flatten: true }`): one socket, and each
/// message to a tab carries that tab's `sessionId`.
@MainActor
final class CDPConnection {
    struct Failure: Error, Equatable {
        let message: String
    }

    /// How a connection ended: never opened (benchd refused, or could not be reached), or lost
    /// after it was. The pane waits differently for each.
    enum Ending: Equatable {
        case refused(String)
        case lost(String)
    }

    /// An event, with its params still undecoded — the receiver decodes the ones it handles.
    struct Event {
        let method: String
        let sessionId: String?
        let raw: Data

        func params<P: Decodable>(_: P.Type) -> P? {
            (try? JSONDecoder().decode(Envelope<P>.self, from: raw))?.params
        }

        private struct Envelope<Params: Decodable>: Decodable {
            let params: Params
        }
    }

    var onEvent: ((Event) -> Void)?
    /// Called once, when the connection is gone for any reason. The string is for the operator.
    var onClose: ((Ending) -> Void)?

    private let link: Link
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var opened = false
    private var closed = false

    init(endpoint: BenchEndpoint) {
        link = Link(endpoint: endpoint)
    }

    func open() {
        link.open(
            opened: { [weak self] in self?.opened = true },
            line: { [weak self] line in self?.dispatch(line) },
            ended: { [weak self] ending in self?.end(ending) })
    }

    func close(_ reason: String = "closed") {
        end(opened ? .lost(reason) : .refused(reason))
    }

    private func end(_ ending: Ending) {
        guard !closed else { return }
        closed = true
        link.close()
        let reason: String
        switch ending {
        case let .refused(why), let .lost(why): reason = why
        }
        for continuation in pending.values {
            continuation.resume(throwing: Failure(message: reason))
        }
        pending.removeAll()
        onClose?(ending)
        onEvent = nil
        onClose = nil
    }

    /// A call whose reply matters.
    @discardableResult
    func call<Result: Decodable>(
        _ method: String, _ params: some Encodable = NoParams(), session: String? = nil,
        returning _: Result.Type = Ignored.self
    ) async throws -> Result {
        let data = try await exchange(method, params, session: session)
        let reply = try JSONDecoder().decode(Reply<Result>.self, from: data)
        if let error = reply.error { throw Failure(message: "\(method): \(error.message)") }
        guard let result = reply.result else { throw Failure(message: "\(method): no result") }
        return result
    }

    /// A call whose reply does not: input, acks. Written to the socket **now**, in call order —
    /// a fire-and-forget `Task` could overtake the next call, and a `stopScreencast` landing
    /// after the `startScreencast` meant to follow it is a pane that never gets a frame
    /// (measured, the first time this ran live). The reply is dropped, as is an error: an input
    /// event that raced a navigation has nowhere useful to report to.
    func send(_ method: String, _ params: some Encodable = NoParams(), session: String? = nil) {
        guard !closed else { return }
        nextID += 1
        guard
            let body = try? JSONEncoder().encode(
                Outgoing(id: nextID, method: method, params: params, sessionId: session))
        else { return }
        link.send(body)
    }

    private func exchange(
        _ method: String, _ params: some Encodable, session: String?
    ) async throws -> Data {
        guard !closed else { throw Failure(message: "the browser connection is closed") }
        nextID += 1
        let id = nextID
        let body = try JSONEncoder().encode(
            Outgoing(id: id, method: method, params: params, sessionId: session))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            link.send(body)
        }
    }

    private func dispatch(_ data: Data) {
        guard !closed else { return }
        guard let peek = try? JSONDecoder().decode(Peek.self, from: data) else { return }
        if let id = peek.id {
            pending.removeValue(forKey: id)?.resume(returning: data)
        } else if let method = peek.method {
            onEvent?(Event(method: method, sessionId: peek.sessionId, raw: data))
        }
    }

    // MARK: - Wire shapes

    struct NoParams: Encodable {}

    /// For a call whose result is `{}` or not needed.
    struct Ignored: Decodable {}

    private struct Outgoing<Params: Encodable>: Encodable {
        let id: Int
        let method: String
        let params: Params
        let sessionId: String?
    }

    private struct Peek: Decodable {
        let id: Int?
        let method: String?
        let sessionId: String?
    }

    private struct Reply<Result: Decodable>: Decodable {
        let result: Result?
        let error: ReplyError?
    }

    private struct ReplyError: Decodable {
        let message: String
    }
}

/// The connection's socket side, off the main actor: one queue writes lines in the order they
/// were sent (the `stopScreencast`/`startScreencast` rule on `send`), and one thread reads.
/// Everything it hears goes to the main actor in the order it arrived.
private final class Link: @unchecked Sendable {
    private let endpoint: BenchEndpoint
    private let writes = DispatchQueue(label: "helm.browser.cdp")
    private let lock = NSLock()
    /// Set on the write queue once `browser/connect` is answered; read under `lock`.
    private var socket: BenchSocket?
    private var closed = false

    init(endpoint: BenchEndpoint) {
        self.endpoint = endpoint
    }

    /// Connect and ask for the relay on the write queue, so every line sent before the answer
    /// waits behind it rather than racing it.
    func open(
        opened: @escaping @MainActor () -> Void,
        line: @escaping @MainActor (Data) -> Void,
        ended: @escaping @MainActor (CDPConnection.Ending) -> Void
    ) {
        writes.async { [self] in
            let socket: BenchSocket
            do {
                socket = try BenchSocket(endpoint: endpoint, timeout: nil)
                try socket.writeLine(
                    JSONEncoder().encode(BrowserConnectRequest(id: "helm-browser-\(UUID())")))
                guard let answer = try socket.readLine() else {
                    throw BenchSocket.Failure(description: "benchd closed the connection")
                }
                let response = try JSONDecoder().decode(
                    BenchResponse<BrowserConnected>.self, from: answer)
                guard response.status == .ok else {
                    throw BenchSocket.Failure(
                        description: response.reason ?? "benchd answered \(response.status)")
                }
            } catch {
                Self.main { ended(.refused("\(error)")) }
                return
            }
            lock.lock()
            let wasClosed = closed
            if !wasClosed { self.socket = socket }
            lock.unlock()
            guard !wasClosed else { return socket.close() }
            Self.main { opened() }
            Thread.detachNewThread { self.read(socket, line: line, ended: ended) }
        }
    }

    private func read(
        _ socket: BenchSocket, line: @escaping @MainActor (Data) -> Void,
        ended: @escaping @MainActor (CDPConnection.Ending) -> Void
    ) {
        let why: String
        do {
            while let next = try socket.readLine() {
                Self.main { line(next) }
            }
            why = "benchd ended the relay"
        } catch {
            why = "\(error)"
        }
        // Closed on the write queue, after any write already queued, and never while one is in
        // flight: a descriptor closed under a writer can be reused by another file before it
        // writes.
        writes.async { [self] in
            lock.lock()
            closed = true
            self.socket = nil
            lock.unlock()
            socket.close()
        }
        Self.main { ended(.lost(why)) }
    }

    func send(_ body: Data) {
        writes.async { [self] in
            lock.lock()
            let socket = closed ? nil : self.socket
            lock.unlock()
            // A write that fails is followed by the reader seeing the same end.
            try? socket?.writeLine(body)
        }
    }

    /// Ends the reader, which closes the socket. Safe from any thread, before or after `open`.
    func close() {
        lock.lock()
        closed = true
        let socket = self.socket
        lock.unlock()
        socket?.interrupt()
    }

    private static func main(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}
