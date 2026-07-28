import Foundation

/// A `URLProtocol` that answers with canned responses — no engine, no network.
///
/// Extracted from `EngineClientTests` when that file was removed. It is shared test
/// infrastructure rather than a test, and it outlived the client it was written for: every
/// HTTP-level assertion in the suite runs through it.
final class StubURLProtocol: URLProtocol {
    /// Injected transport failure, for the cases that never reach a status code —
    /// timeouts, refused connections, dropped sockets. Distinct from a canned response
    /// because those are exactly the paths a status-code stub cannot express.
    nonisolated(unsafe) static var failure: Error?

    /// Fail the next request at the transport layer.
    static func fail(with error: Error) {
        reset()
        failure = error
    }

    private struct Canned {
        let status: Int
        let body: Data
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var canned: Canned?
    private nonisolated(unsafe) static var cannedByPath: [String: Canned] = [:]
    private nonisolated(unsafe) static var _lastRequest: URLRequest?
    private nonisolated(unsafe) static var _lastRequestBody: Data?

    static func respond(status: Int, json: String) {
        lock.lock()
        defer { lock.unlock() }
        canned = Canned(status: status, body: Data(json.utf8))
    }

    /// A response for one endpoint, taking precedence over the catch-all.
    static func respond(path: String, status: Int, json: String) {
        lock.lock()
        defer { lock.unlock() }
        cannedByPath[path] = Canned(status: status, body: Data(json.utf8))
    }

    static func reset() {
        failure = nil
        lock.lock()
        defer { lock.unlock() }
        canned = nil
        cannedByPath = [:]
        _lastRequest = nil
        _lastRequestBody = nil
    }

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _lastRequest
    }

    static var lastRequestBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _lastRequestBody
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let body =
            request.httpBody
            ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
                return data
            }

        Self.lock.lock()
        Self._lastRequest = request
        Self._lastRequestBody = body
        let canned = request.url.flatMap { Self.cannedByPath[$0.path] } ?? Self.canned
        Self.lock.unlock()

        guard let canned else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: canned.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
