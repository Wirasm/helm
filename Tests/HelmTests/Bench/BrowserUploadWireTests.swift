import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The browser pane's `browser/upload` (#549) against `daemon/fixtures/browser-upload.json`,
/// which the daemon gate holds to `bench_wire::BrowserUploadArgs` and `BrowserUploaded`.
final class BrowserUploadWireTests: XCTestCase {
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

    /// The request is the daemon's sample, bytes and all, and the answer decodes.
    func testTheUploadIsSpelledAsTheDaemonSpellsIt() throws {
        let samples =
            try JSONSerialization.jsonObject(with: fixture("browser-upload.json"))
            as! [String: Any]
        func sample(_ key: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: XCTUnwrap(samples[key]))
        }
        let request = BrowserUploadRequest(
            id: "helm-upload-1", name: "report.pdf", bytes: Data("upload-me\n".utf8))
        XCTAssertEqual(try plain(JSONEncoder().encode(request)), try plain(sample("request")))
        let uploaded = try JSONDecoder().decode(
            BenchResponse<BrowserUploaded>.self, from: sample("uploaded"))
        XCTAssertEqual(
            uploaded.data,
            BrowserUploaded(path: "/Users/op/.bench/browser/uploads/1-1759300000/report.pdf"))
    }
}
