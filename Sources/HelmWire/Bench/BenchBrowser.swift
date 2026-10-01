import Foundation

// The browser pane's view onto the shared browser (M5c, #459). Pinned against
// `daemon/fixtures/browser-connect.json`, which the daemon gate holds to the Rust types
// (`Verb::BrowserConnect`, `BrowserConnected`).

/// `browser/connect`, sent as helm. After an ok answer the connection carries CDP messages,
/// one JSON object per line each way: benchd opens the browser's websocket on its own machine,
/// so helm needs neither the endpoint file nor a port there.
package struct BrowserConnectRequest: Encodable, Equatable, Sendable {
    package var id: String
    package var verb = "browser/connect"
    package var by = BenchActor.helm

    package init(id: String) { self.id = id }
}

/// Its answer: the browser the connection now reaches.
package struct BrowserConnected: Decodable, Equatable, Sendable {
    package var pid: Int32

    package init(pid: Int32) { self.pid = pid }
}

/// `browser/upload` (#549): a file the operator chose for a page's file input, sent to a benchd
/// on another machine, which keeps it there and answers its path for `DOM.setFileInputFiles`.
/// Pinned against `daemon/fixtures/browser-upload.json` (`BrowserUploadArgs`, `BrowserUploaded`).
package struct BrowserUploadRequest: Encodable, Equatable, Sendable {
    package var id: String
    package var name: String
    package var bytes: Data

    package init(id: String, name: String, bytes: Data) {
        self.id = id
        self.name = name
        self.bytes = bytes
    }

    private enum CodingKeys: String, CodingKey { case id, verb, by, args }
    private enum ArgKeys: String, CodingKey { case name, base64 }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("browser/upload", forKey: .verb)
        try c.encode(BenchActor.helm, forKey: .by)
        var a = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        try a.encode(name, forKey: .name)
        try a.encode(bytes.base64EncodedString(), forKey: .base64)
    }
}

/// Its answer: where the file is on benchd's machine.
package struct BrowserUploaded: Decodable, Equatable, Sendable {
    package var path: String

    package init(path: String) { self.path = path }
}
