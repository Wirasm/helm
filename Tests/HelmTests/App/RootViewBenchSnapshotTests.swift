import AppKit
import SwiftUI
import XCTest

@testable import Helm

@MainActor
final class RootViewBenchSnapshotTests: XCTestCase {
    func testAppearanceStartsAndDisappearanceStopsBenchSnapshotPublisher() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-root-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        var writes = 0
        let snapshot = BenchSnapshotModel(
            directory: BenchSnapshotDirectory(root: root),
            mailboxRoot: root.appendingPathComponent("mail"),
            refreshInterval: .milliseconds(5),
            writer: { _ in
                writes += 1
                return true
            })
        let hosting = NSHostingView(rootView: RootView(benchSnapshot: snapshot))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil }

        try await waitUntil { writes > 0 }
        window.contentView = nil
        let writesAfterDisappearance = writes
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(writes, writesAfterDisappearance)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1), condition: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("timed out waiting for RootView to start the bench snapshot publisher")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
