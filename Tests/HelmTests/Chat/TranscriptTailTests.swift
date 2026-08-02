import XCTest

@testable import Helm

/// Byte-offset tailing, and the two ways a transcript stops being the file you
/// were reading.
final class TranscriptTailTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-tail-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("transcript.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        url = nil
    }

    private func write(_ text: String) throws {
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func strings(_ batch: TranscriptTail.Batch) -> [String] {
        batch.lines.map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Reading forward

    func testFirstPollReadsTheWholeFile() throws {
        try write("one\ntwo\n")
        var tail = TranscriptTail()
        XCTAssertEqual(strings(tail.poll(url)), ["one", "two"])
    }

    func testSecondPollReadsOnlyWhatWasAppended() throws {
        try write("one\n")
        var tail = TranscriptTail()
        _ = tail.poll(url)

        try append("two\nthree\n")
        XCTAssertEqual(strings(tail.poll(url)), ["two", "three"])
    }

    func testNothingNewYieldsAnEmptyBatch() throws {
        try write("one\n")
        var tail = TranscriptTail()
        _ = tail.poll(url)

        let batch = tail.poll(url)
        XCTAssertTrue(batch.lines.isEmpty)
        XCTAssertFalse(batch.didReset)
    }

    /// Measured never to happen — 860 appends, every one newline-terminated —
    /// but the cost of being wrong is a dropped record and the cost of the carry
    /// buffer is nothing.
    func testAPartialLineIsHeldUntilItsNewlineArrives() throws {
        try write("one\n{\"partial\"")
        var tail = TranscriptTail()
        XCTAssertEqual(strings(tail.poll(url)), ["one"], "the half-written record is held back")

        try append(":true}\n")
        XCTAssertEqual(strings(tail.poll(url)), [#"{"partial":true}"#], "and lands whole")
    }

    /// A 720 KB single append carrying nine records was measured. Nothing about
    /// the size changes the handling.
    func testALargeAppendArrivesWhole() throws {
        try write("")
        var tail = TranscriptTail()
        _ = tail.poll(url)

        let big = String(repeating: "x", count: 300_000)
        try append("\(big)\n\(big)\n")
        let batch = tail.poll(url)
        XCTAssertEqual(batch.lines.count, 2)
        XCTAssertEqual(batch.lines.first?.count, 300_000)
    }

    // MARK: - When it stops being the same file

    /// Truncation: the offset held is past the end, so everything read before is
    /// stale and the caller has to start over.
    func testShrinkingFileSignalsAReset() throws {
        try write("one\ntwo\nthree\n")
        var tail = TranscriptTail()
        _ = tail.poll(url)

        try write("fresh\n")
        let batch = tail.poll(url)
        XCTAssertTrue(batch.didReset)
        XCTAssertEqual(strings(batch), ["fresh"])
    }

    /// Replacement: a different inode at the same path. The offset means nothing
    /// against a file we have never read.
    func testReplacedFileSignalsAReset() throws {
        try write("one\ntwo\n")
        var tail = TranscriptTail()
        _ = tail.poll(url)

        try FileManager.default.removeItem(at: url)
        try write("one\ntwo\nthree\n")
        let batch = tail.poll(url)
        XCTAssertTrue(batch.didReset)
        XCTAssertEqual(strings(batch), ["one", "two", "three"], "a full reparse, not a diff")
    }

    func testMissingFileIsSilentRatherThanAnError() {
        var tail = TranscriptTail()
        let batch = tail.poll(url.appendingPathExtension("nope"))
        XCTAssertTrue(batch.lines.isEmpty)
        XCTAssertFalse(batch.didReset)
    }

    func testBlankLinesAreSkipped() throws {
        try write("one\n\n\ntwo\n")
        var tail = TranscriptTail()
        XCTAssertEqual(strings(tail.poll(url)), ["one", "two"])
    }
}
