import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The pane's downloads list (#549), folded from the events Chrome sends the browser connection.
@MainActor
final class BrowserDownloadsTests: XCTestCase {
    private func event(_ method: String, _ params: String) -> CDPConnection.Event {
        CDPConnection.Event(
            method: method, sessionId: nil,
            raw: Data(#"{"method":"\#(method)","params":\#(params)}"#.utf8))
    }

    /// The shapes Chrome 154 sent in the spike: a begin, progress, and a completed report that
    /// carries the file's path on benchd's machine.
    func testADownloadIsListedAndFinishesWithItsPath() {
        let downloads = BrowserDownloads(endpoint: .unix(path: "/tmp/benchd.sock"))
        downloads.handle(
            event(
                "Browser.downloadWillBegin",
                #"{"frameId":"F","guid":"g1","url":"data:,x","suggestedFilename":"report.pdf"}"#))
        XCTAssertEqual(downloads.items.map(\.name), ["report.pdf"])
        XCTAssertEqual(downloads.items.first?.state, .inProgress)
        downloads.handle(
            event(
                "Browser.downloadProgress",
                #"{"guid":"g1","totalBytes":10,"receivedBytes":5,"state":"inProgress"}"#))
        XCTAssertEqual(downloads.items.first?.receivedBytes, 5)
        downloads.handle(
            event(
                "Browser.downloadProgress",
                #"{"guid":"g1","totalBytes":10,"receivedBytes":10,"state":"completed","#
                    + #""filePath":"/Users/op/Downloads/report.pdf"}"#))
        XCTAssertEqual(downloads.items.first?.state, .completed)
        XCTAssertEqual(downloads.items.first?.path, "/Users/op/Downloads/report.pdf")
    }

    /// Newest first, a cancelled one says so, and Clear keeps only what is still running.
    func testTheListIsNewestFirstAndClearKeepsWhatIsRunning() {
        let downloads = BrowserDownloads(endpoint: nil)
        for (guid, name) in [("a", "a.txt"), ("b", "b.txt"), ("c", "c.txt")] {
            downloads.handle(
                event(
                    "Browser.downloadWillBegin",
                    #"{"frameId":"F","guid":"\#(guid)","url":"u","suggestedFilename":"\#(name)"}"#))
        }
        downloads.handle(
            event(
                "Browser.downloadProgress",
                #"{"guid":"a","totalBytes":1,"receivedBytes":0,"state":"canceled"}"#))
        downloads.handle(
            event(
                "Browser.downloadProgress",
                #"{"guid":"b","totalBytes":1,"receivedBytes":1,"state":"completed","filePath":"/x"}"#
            ))
        XCTAssertEqual(downloads.items.map(\.id), ["c", "b", "a"])
        XCTAssertEqual(downloads.items.last?.state, .canceled)
        downloads.clear()
        XCTAssertEqual(downloads.items.map(\.id), ["c"])
    }

    /// On one machine the file opens where Chrome put it; nothing is copied.
    func testOnOneMachineTheFileIsAlreadyOnTheMac() async throws {
        let downloads = BrowserDownloads(endpoint: .unix(path: "/tmp/benchd.sock"))
        downloads.handle(
            event(
                "Browser.downloadWillBegin",
                #"{"frameId":"F","guid":"g","url":"u","suggestedFilename":"r.pdf"}"#))
        downloads.handle(
            event(
                "Browser.downloadProgress",
                #"{"guid":"g","totalBytes":1,"receivedBytes":1,"state":"completed","#
                    + #""filePath":"/Users/op/Downloads/r.pdf"}"#))
        let url = try await downloads.onMac("g").get()
        XCTAssertEqual(url.path, "/Users/op/Downloads/r.pdf")
    }

    /// Open never runs what an agent could have downloaded: an app, a script, an installer or a
    /// file with the exec bit is shown in Finder. A document opens.
    func testOpenRevealsAnythingRunnableAndOpensADocument() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String, executable: Bool = false) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            return url
        }
        for name in [
            "run.command", "install.sh", "Setup.PKG", "image.dmg", "shell.terminal", "x.tool",
            "auto.workflow", "lib.jar", "do.scpt", "do.applescript", "step.action", "Suite.mpkg",
        ] {
            XCTAssertEqual(BrowserDownloads.openAction(for: try file(name)), .reveal, name)
        }
        let app = folder.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(BrowserDownloads.openAction(for: app), .reveal, "an app bundle")
        XCTAssertEqual(
            BrowserDownloads.openAction(for: try file("tool", executable: true)), .reveal,
            "a file with the exec bit, whatever its name")
        XCTAssertEqual(BrowserDownloads.openAction(for: try file("report.pdf")), .open)
        XCTAssertEqual(BrowserDownloads.openAction(for: try file("notes.txt")), .open)
    }

    /// A copy never replaces a file already on the Mac: `r.pdf`, then `r (2).pdf`, `r (3).pdf`.
    func testACopyTakesTheFirstFreeName() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(BrowserDownloads.freeName("r.pdf", in: folder).lastPathComponent, "r.pdf")
        try Data().write(to: folder.appendingPathComponent("r.pdf"))
        XCTAssertEqual(
            BrowserDownloads.freeName("r.pdf", in: folder).lastPathComponent, "r (2).pdf")
        try Data().write(to: folder.appendingPathComponent("r (2).pdf"))
        XCTAssertEqual(
            BrowserDownloads.freeName("r.pdf", in: folder).lastPathComponent, "r (3).pdf")
        XCTAssertEqual(BrowserDownloads.freeName("notes", in: folder).lastPathComponent, "notes")
    }
}
