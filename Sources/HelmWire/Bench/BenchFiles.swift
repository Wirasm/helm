import Foundation

// The file layer as helm sends and reads it (M5c, #459): a canvas's file, its sibling assets,
// its notes sidecar and an HTML canvas's live file (#532), read and written by benchd. The spelling is
// `bench_wire::files`; `daemon/fixtures/file-verbs.json` pins both sides.

/// `file/read`: a file's bytes, or — with `within` — a page's sibling, which benchd refuses to
/// read from outside that folder.
package struct BenchFileReadRequest: Encodable, Equatable, Sendable {
    package var id: String
    package var path: String
    package var within: String?

    package init(id: String, path: String, within: String? = nil) {
        self.id = id
        self.path = path
        self.within = within
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args }
    private enum ArgKeys: String, CodingKey { case path, within }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("file/read", forKey: .verb)
        var a = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        try a.encode(path, forKey: .path)
        try a.encodeIfPresent(within, forKey: .within)
    }
}

/// `file/read`'s answer. A file benchd could not read is a refusal, never `absent`.
package enum BenchFileRead: Decodable, Equatable, Sendable {
    case bytes(Data)
    case absent
    /// The path leaves the folder `within` named.
    case outside

    private enum CodingKeys: String, CodingKey { case kind, base64 }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "bytes": self = .bytes(try Self.bytes(c.decode(String.self, forKey: .base64), in: c))
        case "absent": self = .absent
        case "outside": self = .outside
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "a file/read answer of kind \(other)")
        }
    }

    fileprivate static func bytes<K>(_ text: String, in c: KeyedDecodingContainer<K>) throws -> Data
    {
        guard let data = Data(base64Encoded: text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: c.codingPath, debugDescription: "base64 that does not decode"))
        }
        return data
    }
}

/// What a `file/write` expects to replace. Every writer names what it saw (#532).
package enum BenchFileExpect: Equatable, Sendable {
    /// Only if the file still holds exactly these bytes, or is gone.
    case unchanged(String)
}

/// `file/write`: the whole file, against what helm expects to replace.
package struct BenchFileWriteRequest: Encodable, Equatable, Sendable {
    package var id: String
    package var path: String
    package var text: String
    package var expect: BenchFileExpect
    /// The operator changed a live file through its page: benchd mails the canvas's opener once
    /// it is written. Encoded only when true, as on the Rust side.
    package var notify: Bool

    package init(
        id: String, path: String, text: String, expect: BenchFileExpect, notify: Bool = false
    ) {
        self.id = id
        self.path = path
        self.text = text
        self.expect = expect
        self.notify = notify
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args }
    private enum ArgKeys: String, CodingKey { case path, text, expect, notify }
    private enum ExpectKeys: String, CodingKey { case kind, text }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("file/write", forKey: .verb)
        var a = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        try a.encode(path, forKey: .path)
        try a.encode(text, forKey: .text)
        var e = a.nestedContainer(keyedBy: ExpectKeys.self, forKey: .expect)
        switch expect {
        case let .unchanged(text):
            try e.encode("unchanged", forKey: .kind)
            try e.encode(text, forKey: .text)
        }
        if notify { try a.encode(true, forKey: .notify) }
    }
}

/// `file/write`'s answer.
package enum BenchFileWrite: Decodable, Equatable, Sendable {
    case written
    /// The file no longer held what `unchanged` named; nothing was written, and these bytes are
    /// there instead.
    case changed(Data)

    private enum CodingKeys: String, CodingKey { case kind, base64 }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "written": self = .written
        case "changed":
            self = .changed(try BenchFileRead.bytes(c.decode(String.self, forKey: .base64), in: c))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "a file/write answer of kind \(other)")
        }
    }
}

/// `file/append`: a note at the end of a canvas's sidecar.
package struct BenchFileAppendRequest: Encodable, Equatable, Sendable {
    package var id: String
    package var path: String
    package var text: String

    package init(id: String, path: String, text: String) {
        self.id = id
        self.path = path
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args }
    private enum ArgKeys: String, CodingKey { case path, text }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("file/append", forKey: .verb)
        var a = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        try a.encode(path, forKey: .path)
        try a.encode(text, forKey: .text)
    }
}

/// `file/append`'s answer: nothing to say but that it happened.
package struct BenchFileAppended: Decodable, Equatable, Sendable {}

/// `file/changed`'s data: a canvas file, or its sidecar, settled into a new state.
package struct BenchFileChanged: Decodable, Equatable, Sendable {
    package static let kind = "file/changed"
    package var path: String
}

/// An HTML canvas's live file (#532): `/a/tasks.html` → `/a/tasks.data.json`, the one JSON file
/// the page and the agent both edit. `bench_wire::live_file` is the same rule, pinned by
/// `file-verbs.json`'s `live_files` table.
package enum BenchLiveFile {
    package static let suffix = ".data.json"

    /// The live file beside `canvas`, or nil for a canvas that is not HTML.
    package static func path(for canvas: String) -> String? {
        let slash = canvas.lastIndex(of: "/")
        let name = slash.map { canvas[canvas.index(after: $0)...] } ?? canvas[...]
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        guard ["html", "htm"].contains(name[name.index(after: dot)...].lowercased()) else {
            return nil
        }
        let directory = slash.map { String(canvas[..<$0]) } ?? ""
        return "\(directory)/\(name[..<dot])\(suffix)"
    }
}
