import Foundation

// What helm and benchd say to each other beyond the document (M3, #355): the daemon's `status`,
// read for the `bench` binary a pane runs to show a session, and benchd asking helm for what
// only the window can do. Pinned against `daemon/fixtures/helm-ask.json`, which the daemon gate
// holds to the Rust types (`HelmAsked`, `HelmAnswer`).

/// `status`, which takes no arguments.
package struct BenchStatusRequest: Encodable, Equatable, Sendable {
    package var id: String
    package var verb = "status"

    package init(id: String) { self.id = id }
}

/// `status`'s answer, reduced to what helm reads.
package struct BenchStatusReply: Decodable, Equatable, Sendable {
    /// The `bench` beside this benchd: what a pane runs to show one of its sessions.
    package var bench: String?
    /// This benchd's build (`bench_wire::VERSION`), which `bench --version` prints too.
    package var version: String?

    package init(bench: String?, version: String?) {
        self.bench = bench
        self.version = version
    }
}

/// The data of a `helm/asked` event: an ask benchd holds a caller waiting on.
package struct HelmAsked: Codable, Equatable, Sendable {
    package var ask: String
    package var request: HelmAsk

    package init(ask: String, request: HelmAsk) {
        self.ask = ask
        self.request = request
    }
}

/// What benchd asks. Tagged by `kind`; one this build does not know is `unknown`, answered with a
/// refusal naming it rather than left to time out.
package enum HelmAsk: Codable, Equatable, Sendable {
    /// Draw the window titled like `window` if named, and answer with the PNG itself
    /// (`CaptureAnswer`). benchd writes the file on its own side (M5c): helm is never told a path,
    /// since the caller's is on benchd's machine.
    case capture(window: String?)
    case unknown(kind: String)

    private enum CodingKeys: String, CodingKey { case kind, window }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "capture":
            self = .capture(window: try c.decodeIfPresent(String.self, forKey: .window))
        case let other:
            self = .unknown(kind: other)
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .capture(window):
            try c.encode("capture", forKey: .kind)
            try c.encodeIfPresent(window, forKey: .window)
        case let .unknown(kind):
            try c.encode(kind, forKey: .kind)
        }
    }
}

/// The largest request line benchd reads for `helm/answer`, `file/write`, `file/append` and
/// `browser/upload` (`bench_wire::FILE_REQUEST_MAX_BYTES`). A capture answer or an upload longer
/// than this would be refused unread and leave the caller waiting, so helm refuses it first and
/// says why.
package let benchLargeRequestMaxBytes = 16 * 1024 * 1024

/// `helm/answer`: helm's outcome for one ask, sent as helm. benchd hands `status`, `reason` and
/// `data` to the waiting caller unchanged.
package struct HelmAnswerRequest<Data: Encodable & Equatable>: Encodable, Equatable {
    package var id: String
    package var ask: String
    package var status: BenchStatus
    package var reason: String?
    package var data: Data?

    package init(id: String, ask: String, status: BenchStatus, reason: String?, data: Data?) {
        self.id = id
        self.ask = ask
        self.status = status
        self.reason = reason
        self.data = data
    }

    private enum CodingKeys: String, CodingKey { case id, verb, by, args }
    private enum ArgKeys: String, CodingKey { case ask, status, reason, data }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("helm/answer", forKey: .verb)
        try c.encode(BenchActor.helm, forKey: .by)
        var args = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        try args.encode(ask, forKey: .ask)
        try args.encode(status, forKey: .status)
        try args.encodeIfPresent(reason, forKey: .reason)
        try args.encodeIfPresent(data, forKey: .data)
    }
}

/// A `bench/changed` event's data, reduced to what helm reads of an agent's verb: which verb, who
/// sent it, and the pane it resolved to. helm reads it to remember which agent opened a canvas,
/// so a mark on it can be mailed back (#205).
package struct BenchChange: Decodable, Equatable, Sendable {
    package var verb: String
    package var by: BenchActor
    package var pane: UUID?

    package init(verb: String, by: BenchActor, pane: UUID?) {
        self.verb = verb
        self.by = by
        self.pane = pane
    }
}
