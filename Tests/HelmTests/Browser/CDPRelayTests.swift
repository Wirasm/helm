import Darwin
import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The browser pane reaches the shared browser through benchd (M5c): it asks `browser/connect`
/// and speaks CDP as lines on that connection. A stand-in benchd plays the relay here; benchd's
/// own relay to a websocket is the daemon gate's (`browser_connect_relays_…` in conformance).
@MainActor
final class CDPRelayTests: XCTestCase {
    private static let empty = DocumentAt(
        seq: 1, document: BenchDocument(workspaces: [], active: nil))

    /// A stand-in browser behind the relay: answers every call by id, `Target.getTargets` with
    /// one tab, and sends one event first.
    nonisolated private static func browser(_ fd: Int32) {
        let tab = #"{"targetId":"t1","type":"page","url":"https://example.com/","title":"Example"}"#
        let event = #"{"method":"Target.targetInfoChanged","params":{"targetInfo":"# + tab + "}}"
        send(fd, event)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var open = true
        while open {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard
                    let call = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let id = call["id"] as? Int
                else { continue }
                let result: String =
                    switch call["method"] as? String {
                    case "Target.getTargets": #"{"targetInfos":["# + tab + "]}"
                    case "Target.attachToTarget": #"{"sessionId":"s1"}"#
                    case "Browser.close": ""
                    default: "{}"
                    }
                // `Browser.close` stands in for the browser going away: the relay ends.
                if result.isEmpty {
                    open = false
                    break
                }
                send(fd, #"{"id":\#(id),"result":\#(result)}"#)
            }
        }
        close(fd)
    }

    nonisolated private static func send(_ fd: Int32, _ line: String) {
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
    }

    private func relayingBenchd() throws -> FakeBenchd {
        let benchd = try FakeBenchd(document: Self.empty, tcp: true)
        benchd.answer = { request in
            ["id": request["id"] ?? "", "status": "ok", "data": ["pid": 4242]]
        }
        benchd.relay = { fd in Self.browser(fd) }
        return benchd
    }

    private func until(_ what: String, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testACallIsAnsweredAndAnEventArrivesThroughTheRelay() async throws {
        let benchd = try relayingBenchd()
        defer { benchd.stop() }
        let connection = CDPConnection(endpoint: benchd.endpoint)
        var events: [String] = []
        connection.onEvent = { events.append($0.method) }
        connection.open()

        struct Targets: Decodable { let targetInfos: [BrowserTab] }
        let targets = try await connection.call("Target.getTargets", returning: Targets.self)
        XCTAssertEqual(targets.targetInfos.map(\.targetId), ["t1"])
        XCTAssertEqual(events, ["Target.targetInfoChanged"])
        let asked = benchd.requests.first { $0["verb"] as? String == "browser/connect" }
        XCTAssertEqual((asked?["by"] as? [String: Any])?["kind"] as? String, "helm")
        connection.close()
    }

    /// benchd's refusal is what the pane says, and a call waiting on the connection fails
    /// rather than hanging.
    func testARefusalEndsTheConnectionWithBenchdsReason() async throws {
        let benchd = try FakeBenchd(document: Self.empty, tcp: true)
        defer { benchd.stop() }
        benchd.answer = { request in
            [
                "id": request["id"] ?? "", "status": "refused",
                "reason": "no shared browser is running. `bench browser start` starts one",
            ]
        }
        let connection = CDPConnection(endpoint: benchd.endpoint)
        var ended: CDPConnection.Ending?
        connection.onClose = { ended = $0 }
        connection.open()
        do {
            try await connection.call("Target.getTargets")
            XCTFail("a call on a refused connection must fail")
        } catch {}
        XCTAssertEqual(
            ended, .refused("no shared browser is running. `bench browser start` starts one"))
    }

    /// The relay ending after it opened is a lost browser, not a refusal.
    func testTheRelayEndingIsALostBrowser() async throws {
        let benchd = try relayingBenchd()
        defer { benchd.stop() }
        let connection = CDPConnection(endpoint: benchd.endpoint)
        var ended: CDPConnection.Ending?
        connection.onClose = { ended = $0 }
        connection.open()
        try await connection.call("Page.enable")
        connection.send("Browser.close")
        try await until("the relay to end") { ended != nil }
        guard case .lost = ended else { return XCTFail("\(String(describing: ended))") }
    }

    func testThePaneConnectsThroughBenchdAndListsTheTabs() async throws {
        let benchd = try relayingBenchd()
        defer { benchd.stop() }
        let pane = BrowserPaneModel(endpoint: benchd.endpoint)
        defer { pane.close() }
        try await until("the pane to connect") { pane.status == .connected }
        XCTAssertEqual(pane.tabs.tabs.map(\.targetId), ["t1"])
    }

    func testAPaneWithNoBrowserWaitsWithBenchdsSentence() async throws {
        let benchd = try FakeBenchd(document: Self.empty, tcp: true)
        defer { benchd.stop() }
        benchd.answer = { request in
            [
                "id": request["id"] ?? "", "status": "refused",
                "reason": "no shared browser is running. `bench browser start` starts one",
            ]
        }
        let pane = BrowserPaneModel(endpoint: benchd.endpoint)
        defer { pane.close() }
        try await until("the pane to wait") {
            if case .waiting = pane.status { true } else { false }
        }
        XCTAssertEqual(
            pane.status,
            BrowserPaneModel.Status.waiting(
                "No shared browser is running. `bench browser start` starts one. This pane "
                    + "connects when it appears."))
    }
}
