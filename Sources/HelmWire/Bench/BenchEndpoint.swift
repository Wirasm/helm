import Foundation

/// Where helm reaches benchd: the bench root's unix socket, or a benchd on another machine named
/// by `BENCH_URL=tcp://<host>:<port>` (M5c, #459). `bench_wire::Endpoint` spelled again, and
/// `daemon/fixtures/bench-url.json` is the table both copies answer the same way
/// (`BenchWireConformanceTests` here, `bench-wire`'s own tests there).
package enum BenchEndpoint: Equatable, Sendable, CustomStringConvertible {
    case unix(path: String)
    /// `host` without the brackets an IPv6 address is written in.
    case tcp(host: String, port: UInt16)

    package static let urlVariable = "BENCH_URL"

    /// `BENCH_URL` when set: `tcp://<host>:<port>` and nothing else. Unset or empty is `socket`.
    /// nil for any other value, which the caller refuses by name.
    static func parse(url: String?, socket: String) -> BenchEndpoint? {
        guard let url, !url.isEmpty else { return .unix(path: socket) }
        guard url.hasPrefix("tcp://") else { return nil }
        let address = url.dropFirst("tcp://".count)
        guard let colon = address.lastIndex(of: ":"),
            let port = UInt16(address[address.index(after: colon)...]), port > 0
        else { return nil }
        var host = address[..<colon]
        // An IPv6 host is bracketed, so the last `:` is the port's; any other host has none.
        let bracketed = host.hasPrefix("[") && host.hasSuffix("]") && host.count >= 2
        if bracketed { host = host.dropFirst().dropLast() }
        guard !host.isEmpty, !host.contains(where: { "[]/".contains($0) }),
            bracketed || !host.contains(":")
        else { return nil }
        return .tcp(host: String(host), port: port)
    }

    /// The form `bench` prints: the socket's path, or the URL.
    package var description: String {
        switch self {
        case let .unix(path): path
        case let .tcp(host, port) where host.contains(":"): "tcp://[\(host)]:\(port)"
        case let .tcp(host, port): "tcp://\(host):\(port)"
        }
    }
}
