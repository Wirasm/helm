import Foundation

/// Where the shared browser is, as benchd publishes it (#350).
///
/// benchd starts one Chrome per bench root and writes this to `<root>/browser/endpoint.json`
/// while that browser runs headless; the file is gone when it stops, and absent while the
/// profile is open in a plain window for `bench browser setup`, which has no address. helm reads it and opens the
/// browser-level CDP websocket (`ws`) itself — benchd is never in the frame path.
///
/// **A duplicate across a runtime boundary, pinned rather than trusted.** The type is
/// `bench_wire::BrowserEndpoint` in `daemon/crates/bench-wire`, and Rust cannot be imported
/// here. `daemon/fixtures/browser-endpoint.json` is the one sample both sides test against:
/// the daemon's conformance suite asserts it writes exactly those keys, and
/// `BrowserEndpointTests` decodes that same file with this type — so a rename on either side
/// is a red gate, not a pane that silently never connects.
struct BrowserEndpoint: Codable, Equatable {
    static let expectedFormat = "bench.browser-endpoint"
    static let supportedVersion = 1

    let format: String
    let version: Int
    /// What `playwright-cli attach --cdp=` takes.
    let cdp: String
    /// The browser-level websocket, what this pane opens.
    let ws: String
    let port: Int
    let pid: Int32
    let binary: String
    let profile: String
    let startedAt: String

    private enum CodingKeys: String, CodingKey {
        case format, version, cdp, ws, port, pid, binary, profile
        case startedAt = "started_at"
    }

    /// What reading the file found. Absence is ordinary — no browser is running — and is
    /// told apart from a file this build cannot read, which is a version skew to report.
    enum Reading: Equatable {
        case absent
        case unreadable(String)
        case found(BrowserEndpoint)
    }

    static func read(at url: URL) -> Reading {
        guard let data = try? Data(contentsOf: url) else { return .absent }
        guard let endpoint = try? JSONDecoder().decode(BrowserEndpoint.self, from: data) else {
            return .unreadable("\(url.path) is not a browser endpoint this helm can read")
        }
        guard endpoint.format == expectedFormat, endpoint.version == supportedVersion else {
            return .unreadable(
                "\(url.path) is \(endpoint.format) v\(endpoint.version); this helm reads "
                    + "\(expectedFormat) v\(supportedVersion)")
        }
        return .found(endpoint)
    }

    var webSocketURL: URL? { URL(string: ws) }

    /// Where benchd writes this file under a bench root (`BenchRoot.resolve`).
    static func url(in root: URL) -> URL {
        root.appendingPathComponent("browser/endpoint.json")
    }
}
