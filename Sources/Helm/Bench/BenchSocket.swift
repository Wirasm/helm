import Darwin
import Foundation

/// One connection to benchd's unix socket, spoken as benchd speaks it: one JSON line out, then
/// lines back. Blocking on purpose — the request path is one short round trip on a local socket
/// (spike S1: p99 under 6 ms end to end), and the follower runs on a thread of its own.
///
/// Not `Sendable`: a connection belongs to the one thread that opened it.
final class BenchSocket {
    struct Failure: Error, Equatable, CustomStringConvertible {
        let description: String
    }

    private let fd: Int32
    private var buffer = Data()
    private var closed = false

    /// Connect, with `timeout` bounding every read and write after it. nil timeout is a
    /// connection that may wait for ever, which only the follower wants: frames arrive when
    /// something changes, and an idle bench changes nothing for hours.
    init(path: String, timeout: TimeInterval?) throws {
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
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Failure(description: "socket(): \(String(cString: strerror(errno)))")
        }
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        if let timeout {
            var tv = timeval(
                tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
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
