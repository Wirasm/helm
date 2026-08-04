import XCTest

@testable import Helm

/// The claim `BoardModel` declined to make, measured.
///
/// `BoardModel.swift` polls and says why: *"a status change rewrites an existing file, which
/// the directory-level `DispatchSource` pattern would not reliably see."* That is right, and it
/// is about a **different event**. These two tests pin the distinction the spool depends on: a
/// directory vnode source reports entries appearing and disappearing, and does not report an
/// in-place write to a file already listed. The board needs the second; the spool needs only
/// the first.
///
/// Both budgets are generous on purpose. The positive one waits far longer than a vnode event
/// takes so a loaded machine cannot fail it; the negative one waits long enough that an event
/// would have arrived if one were coming.
@MainActor
final class SpoolWatcherTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-spool-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    /// A counter the watcher bumps, read from the main actor only.
    private final class Ticks {
        var count = 0
    }

    private func watcher(_ ticks: Ticks) -> SpoolWatcher {
        // A backstop far beyond any test's lifetime, so nothing here can pass on the rescan
        // and quietly leave the watch untested.
        SpoolWatcher(directory: root, backstop: .seconds(600)) { ticks.count += 1 }
    }

    private func wait(for ticks: Ticks, toReach target: Int, within budget: Duration) async {
        let expiry = ContinuousClock.now.advanced(by: budget)
        while ContinuousClock.now < expiry, ticks.count < target {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testStartingLooksOnceWithoutWaitingForAnEvent() async {
        // Requests written while helm was down fire no event at all — without this they would
        // sit unread until the next one arrived.
        let ticks = Ticks()
        let watcher = watcher(ticks)
        watcher.start()
        defer { watcher.stop() }
        XCTAssertEqual(ticks.count, 1)
    }

    func testAFileAppearingFiresTheWatch() async throws {
        let ticks = Ticks()
        let watcher = watcher(ticks)
        watcher.start()
        defer { watcher.stop() }
        XCTAssertEqual(ticks.count, 1, "the initial look")

        try "{}".write(
            to: root.appendingPathComponent("r.json"), atomically: true, encoding: .utf8)
        await wait(for: ticks, toReach: 2, within: .seconds(10))
        XCTAssertGreaterThanOrEqual(
            ticks.count, 2, "a new entry in the directory must reach the watcher")
    }

    func testAFileRewrittenInPlaceDoesNotFireTheWatch() async throws {
        // The board's case, and the reason it polls. Writing *through* an existing entry does
        // not touch the directory, so the directory's vnode source has nothing to report.
        let file = root.appendingPathComponent("status.json")
        try #"{"status":"busy"}"#.write(to: file, atomically: true, encoding: .utf8)

        let ticks = Ticks()
        let watcher = watcher(ticks)
        watcher.start()
        defer { watcher.stop() }
        XCTAssertEqual(ticks.count, 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(#"{"status":"idle"}"#.utf8))
        try handle.close()

        // Nothing to wait *for*: give an event every chance to arrive, then assert none did.
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(
            ticks.count, 1,
            "an in-place rewrite is invisible to a directory watch — which is exactly why "
                + "BoardModel polls and why the spool does not have to")
    }

    func testTheBackstopRescansEvenWithNoEventAtAll() async {
        // Insurance, not the mechanism: a missed event must cost latency rather than a spawn
        // that silently never happens.
        let ticks = Ticks()
        let watcher = SpoolWatcher(directory: root, backstop: .milliseconds(150)) {
            ticks.count += 1
        }
        watcher.start()
        defer { watcher.stop() }
        await wait(for: ticks, toReach: 3, within: .seconds(10))
        XCTAssertGreaterThanOrEqual(ticks.count, 3)
    }
}
