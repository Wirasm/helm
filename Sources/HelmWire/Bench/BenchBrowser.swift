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
