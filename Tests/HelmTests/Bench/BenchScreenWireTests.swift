import Foundation
import HelmWire
import XCTest

/// Pocket's screen verbs (#625) against `daemon/fixtures/screen-verbs.json`, which the daemon gate
/// holds to `bench_wire::ScreenGetArgs`, `ScreenSendArgs` and `ScreenAnswer`.
final class BenchScreenWireTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    private func plain(_ data: Data) throws -> NSObject {
        try JSONSerialization.jsonObject(with: data) as! NSObject
    }

    /// A read, a key and a message are written as benchd reads them,
    /// and its screen answer decodes. The daemon gate reads the same file into `ScreenGetArgs`
    /// and `ScreenSendArgs`, so a key that lost `keys: true` would be pasted, and fail there.
    func testTheScreenRequestsAndAnswerMatchTheDaemonsFixture() throws {
        let samples =
            try JSONSerialization.jsonObject(with: fixture("screen-verbs.json")) as! [String: Any]
        func sample(_ key: String) throws -> NSObject {
            try plain(JSONSerialization.data(withJSONObject: XCTUnwrap(samples[key])))
        }
        XCTAssertEqual(
            try plain(
                JSONEncoder().encode(BenchScreenRequest.get(id: "pocket-1", target: "s7"))),
            try sample("get"))
        XCTAssertEqual(
            try plain(
                JSONEncoder().encode(
                    BenchScreenRequest.send(id: "pocket-2", target: "s7", input: .keys("\u{1b}")))),
            try sample("send"))
        XCTAssertEqual(
            try plain(
                JSONEncoder().encode(
                    BenchScreenRequest.send(
                        id: "pocket-3", target: "s7", input: .message("status?")))),
            try sample("message"))

        let screen = try JSONDecoder().decode(
            BenchScreen.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(samples["get_reply"])))
        XCTAssertEqual(screen.lines, ["› status?", "attention: building.", "", "> "])
    }
}
