import XCTest

@testable import Helm

/// `FileWatcher`, against a real file and a real `DispatchSource` (#109).
///
/// **A non-atomic write is not an exotic case, which is why the debounce is acceptance and not
/// polish.** `.write`/`.extend` fire per *write*, not per *save*: `>` in a shell, a `FileHandle`,
/// an agent streaming a long document. Each event used to re-read the file and re-render it, so
/// the operator watched a truncated page, then a longer truncated page, then the real one.
///
/// **The interval is passed in rather than taken from the default**, so nothing here is a
/// measurement of 120ms — these would still hold if that number changed tomorrow. What they
/// measure is the rule: writes inside one quiet window are one render, and writes either side of
/// one are two.
@MainActor
final class FileWatcherTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-watch-\(UUID().uuidString).md")
        try "".write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    /// **The acceptance: a partial write never renders.** The file is written in three chunks the
    /// way a streaming writer produces them, and what the render sees is the finished document —
    /// once.
    func testAWriteThatArrivesInChunksRendersOnceAndOnlyWhenItIsWhole() async throws {
        var renders: [String] = []
        let watcher = FileWatcher(url: file, debounce: .milliseconds(150)) { [file] in
            renders.append((try? String(contentsOf: file!, encoding: .utf8)) ?? "<unreadable>")
        }
        defer { _ = watcher }

        let handle = try FileHandle(forWritingTo: file)
        for chunk in ["# Plan\n", "\n## Phase one\n", "\nShip it.\n"] {
            try handle.write(contentsOf: Data(chunk.utf8))
            try await Task.sleep(for: .milliseconds(20))
        }
        try handle.close()

        try await settle(for: .milliseconds(500))

        XCTAssertEqual(
            renders.count, 1,
            "three writes inside one quiet window are one save — rendering each of them puts a "
                + "truncated document on screen, twice, before the real one")
        XCTAssertEqual(
            renders.first, "# Plan\n\n## Phase one\n\nShip it.\n",
            "and the one render is of the WHOLE file — a render that fired mid-write would "
                + "show `# Plan` and stop")
    }

    /// **The control, and it is the one that matters most.** A debounce that never fires is a
    /// canvas that silently stops updating — the failure with no symptom, and strictly worse
    /// than the flicker it replaced. Two saves, either side of the window, are two renders.
    func testTwoSavesApartAreStillTwoRenders() async throws {
        var renders = 0
        let watcher = FileWatcher(url: file, debounce: .milliseconds(80)) { renders += 1 }
        defer { _ = watcher }

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("first\n".utf8))
        try await settle(for: .milliseconds(300))
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()
        try await settle(for: .milliseconds(300))

        XCTAssertEqual(renders, 2, "coalescing across separate saves would lose one entirely")
    }

    /// The atomic path — write-to-temp + rename, which is what editors and most agents do. It
    /// goes through the same funnel, so it is debounced too, and it must still arrive.
    ///
    /// **A control in the other direction**: it passed before the debounce and passes after. It
    /// is here because the rename branch re-opens the file descriptor on a *different* code path
    /// from the write branch, and a debounce wired into only one of them would leave the
    /// commonest save in helm's own workflow reporting nothing at all.
    func testAnAtomicReplacementStillReachesThePane() async throws {
        var renders: [String] = []
        let watcher = FileWatcher(url: file, debounce: .milliseconds(80)) { [file] in
            renders.append((try? String(contentsOf: file!, encoding: .utf8)) ?? "<unreadable>")
        }
        defer { _ = watcher }

        try "rewritten by the agent\n".write(to: file, atomically: true, encoding: .utf8)
        try await settle(for: .milliseconds(600))

        XCTAssertEqual(renders, ["rewritten by the agent\n"])
    }

    /// The `DispatchSource` fires on the main queue and the debounce is a `Task`, so the effect
    /// lands on a later turn of the run loop than the write. Sleeping is what lets it.
    private func settle(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
