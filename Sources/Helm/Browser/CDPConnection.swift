import Foundation

/// One Chrome DevTools Protocol websocket: numbered calls with typed replies, and events.
///
/// **Only what the pane needs.** CDP is a large protocol, and agents already have a complete
/// client for it (Playwright). The pane speaks the few methods that show a tab and forward
/// the operator's hands — and nothing here is meant to grow into browser automation.
///
/// Sessions are *flat* (`Target.attachToTarget { flatten: true }`): one socket, and each
/// message to a tab carries that tab's `sessionId`.
@MainActor
final class CDPConnection {
    struct Failure: Error, Equatable {
        let message: String
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
    /// Called once, when the socket is gone for any reason. The string is for the operator.
    var onClose: ((String) -> Void)?

    private let task: URLSessionWebSocketTask
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var closed = false

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        // A screencast frame is a base64 JPEG of the whole pane at backing scale: several
        // hundred KB on a retina display, over the 1 MB default on a large one.
        task.maximumMessageSize = 64 << 20
    }

    func open() {
        task.resume()
        receive()
    }

    func close(_ reason: String = "closed") {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
        for continuation in pending.values {
            continuation.resume(throwing: Failure(message: reason))
        }
        pending.removeAll()
        onClose?(reason)
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
        task.send(.string(String(decoding: body, as: UTF8.self))) { _ in }
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
            task.send(.string(String(decoding: body, as: UTF8.self))) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.fail(id, error) }
            }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receive() {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case let .failure(error):
                    self.close("the browser went away (\(error.localizedDescription))")
                case let .success(message):
                    let data: Data
                    switch message {
                    case let .string(text): data = Data(text.utf8)
                    case let .data(bytes): data = bytes
                    @unknown default: data = Data()
                    }
                    self.dispatch(data)
                    self.receive()
                }
            }
        }
    }

    private func dispatch(_ data: Data) {
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
