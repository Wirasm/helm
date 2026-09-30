import Darwin
import Foundation
import HelmWire

/// One connection to benchd, spoken as benchd speaks it: one JSON line out, then lines back.
/// Blocking on purpose — the request path is one short round trip on a local socket (spike S1:
/// p99 under 6 ms end to end), and the follower runs on a thread of its own.
///
/// The root's unix socket, or TCP to a benchd on another machine (`BenchEndpoint`, M5c): the
/// protocol is the same bytes either way.
///
/// Not `Sendable`: a connection belongs to the one thread that opened it.
final class BenchSocket {
    struct Failure: Error, Equatable, CustomStringConvertible {
        let description: String
    }

    private let fd: Int32
    private var buffer = Data()
    /// How much of `buffer` is known to hold no newline, so a line of several MB (a screencast
    /// frame on the browser relay) is scanned once rather than once per chunk read.
    private var scanned = 0
    private var closed = false

    /// Connect, with `timeout` bounding every read and write after it. nil timeout is a
    /// connection that may wait for ever, which only the follower wants: frames arrive when
    /// something changes, and an idle bench changes nothing for hours.
    init(endpoint: BenchEndpoint, timeout: TimeInterval?) throws {
        switch endpoint {
        case let .unix(path): fd = try Self.connectUnix(path)
        case let .tcp(host, port): fd = try Self.connectTCP(host: host, port: port)
        }
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        if let timeout {
            var tv = timeval(
                tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private static func connectUnix(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw Failure(description: "the socket path is too long for a unix socket: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Failure(description: "socket(): \(String(cString: strerror(errno)))")
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let why = String(cString: strerror(errno))
            Darwin.close(fd)
            throw Failure(description: "benchd is not answering at \(path): \(why)")
        }
        return fd
    }

    /// The first address `host` resolves to that accepts. `TCP_NODELAY`, because a keystroke is
    /// one small write, and keepalive, so a link that died while the Mac slept ends the follower's
    /// read in about 25 s and it reconnects, instead of waiting for frames that never come.
    /// The same settings as `bench_wire::Endpoint::connect`.
    private static func connectTCP(host: String, port: UInt16) throws -> Int32 {
        let named = BenchEndpoint.tcp(host: host, port: port).description
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let resolved = getaddrinfo(host, String(port), &hints, &list)
        guard resolved == 0 else {
            throw Failure(
                description: "cannot resolve \(named): \(String(cString: gai_strerror(resolved)))")
        }
        defer { freeaddrinfo(list) }
        var why = "no address"
        var next = list
        while let info = next?.pointee {
            next = info.ai_next
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            guard fd >= 0 else { continue }
            guard connect(fd, info.ai_addr, info.ai_addrlen) == 0 else {
                why = String(cString: strerror(errno))
                Darwin.close(fd)
                continue
            }
            let options: [(Int32, Int32, Int32)] = [
                (IPPROTO_TCP, TCP_NODELAY, 1),
                (SOL_SOCKET, SO_KEEPALIVE, 1),
                (IPPROTO_TCP, TCP_KEEPALIVE, 10),
                (IPPROTO_TCP, TCP_KEEPINTVL, 5),
                (IPPROTO_TCP, TCP_KEEPCNT, 3),
            ]
            for (level, name, value) in options {
                var value = value
                setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size))
            }
            return fd
        }
        throw Failure(description: "benchd is not answering at \(named): \(why)")
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    /// Wake a thread blocked in `readLine` from another thread; it then reads end of file.
    /// The descriptor stays open until `close`, so it cannot be reused under the reader.
    func interrupt() {
        shutdown(fd, SHUT_RDWR)
    }

    func writeLine(_ line: Data) throws {
        var bytes = line
        bytes.append(0x0A)
        try bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                guard n > 0 else {
                    throw Failure(
                        description:
                            "could not write to benchd: \(String(cString: strerror(errno)))")
                }
                sent += n
            }
        }
    }

    /// The next line without its newline, or nil at end of file.
    func readLine() throws -> Data? {
        while true {
            let from = buffer.index(buffer.startIndex, offsetBy: scanned)
            if let newline = buffer[from...].firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                scanned = 0
                return line
            }
            scanned = buffer.count
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = recv(fd, &chunk, chunk.count, 0)
            if n == 0 { return nil }
            guard n > 0 else {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK {
                    throw Failure(description: "benchd did not answer in time")
                }
                throw Failure(
                    description: "could not read from benchd: \(String(cString: strerror(code)))")
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
