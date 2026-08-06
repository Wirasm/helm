import XCTest

@testable import Helm

/// Byte-offset tailing, and the three ways a transcript stops being the file you
/// were reading: it was replaced, it shrank, or it was rewritten where it stood.
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

    /// Truncate and rewrite **through the same inode** — node's
    /// `openSync(path, "w")`, which is exactly what pi's `SessionManager`
    /// `_rewriteFile()` does (`dist/core/session-manager.js:696` in the pi
    /// installed on this machine), reached from the pre-v3 migration at `:634`
    /// and from the branch/resume path at `:1143`.
    ///
    /// Spelled out rather than reusing `write(_:)` because the whole point of
    /// these cases is *which* of the two things happened, and a helper that
    /// happens to keep the inode today is not the same as one that promises to.
    /// Every caller asserts the inode itself.
    private func rewriteInPlace(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func inode() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
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

    /// **#92.** An in-place rewrite that ends up **longer** than the offset held:
    /// same inode, and the file grew, so neither of the two guards above sees
    /// anything. The bytes from the stale offset are the middle of records that
    /// were never read — measured on the base build, this test's own file yields
    /// `["ta", "gamma"]`, and both of those go straight onto the tape.
    func testInPlaceRewriteEndingLongerThanTheOffsetSignalsAReset() throws {
        try write("one\ntwo\n")
        var tail = TranscriptTail()
        _ = tail.poll(url)
        XCTAssertEqual(tail.offset, 8, "the whole file was read")

        let before = try inode()
        try rewriteInPlace("alpha\nbeta\ngamma\n")
        XCTAssertEqual(
            try inode(), before,
            "the rewrite has to be in place, or this measures the inode guard instead")

        let batch = tail.poll(url)
        XCTAssertTrue(batch.didReset, "a rewrite is not an append, whatever the size says")
        XCTAssertEqual(strings(batch), ["alpha", "beta", "gamma"], "a full reparse, not a diff")
    }

    /// The same rewrite carrying pi's own header line, and differing from it only
    /// in the middle: `version` 2 → 3 is what the pre-v3 migration changes, and it
    /// sits at byte 28. Measured over the 2,281 pi sessions on this machine, the
    /// header line runs 126–334 bytes (median 156), so the head window reaches all
    /// of it; Claude Code's first record has a median of 2,376 bytes and carries
    /// `sessionId`, `uuid` and `timestamp` inside the first 512.
    func testAHeaderLineRewrittenInPlaceSignalsAReset() throws {
        let header = { (version: Int) in
            """
            {"type":"session","version":\(version),"id":"019f9320-d9c6-7bc5-8d94-3cd00ff5e1a8",\
            "timestamp":"2026-07-24T07:57:11.494Z","cwd":"/Users/rasmus/.config/kild"}
            """
        }
        try write(header(2) + "\n{\"type\":\"message\",\"n\":1}\n")
        var tail = TranscriptTail()
        _ = tail.poll(url)

        let before = try inode()
        try rewriteInPlace(
            header(3) + "\n{\"type\":\"message\",\"n\":1}\n{\"type\":\"message\",\"n\":2}\n")
        XCTAssertEqual(try inode(), before, "in place, same as the migration does it")

        let batch = tail.poll(url)
        XCTAssertTrue(batch.didReset, "the version bump is inside the head window")
        XCTAssertEqual(batch.lines.count, 3)
    }

    /// **#92, the case both reviewers of the first cut reproduced.** An in-place
    /// rewrite that ends up **exactly** as long as the offset held.
    ///
    /// Not contrived: pi's v2→v3 migration is `"version":2` → `"version":3`, one
    /// digit for another, and `migrateV2ToV3` changes nothing else unless the
    /// session carries a `hookMessage` — so the rewritten file is byte-for-byte
    /// the same length. It also lands precisely when the tail is idle, which is
    /// the steady state of a poll running four times a second.
    ///
    /// The first cut read the head only after `guard size > offset`, so this poll
    /// returned before opening the file: no reset, and — because it never
    /// arrives — no self-correction from a later append either. A session that
    /// branches and then ends leaves the tape frozen on the old conversation for
    /// as long as the view is open.
    func testInPlaceRewriteEndingTheSameLengthSignalsAReset() throws {
        let header = { (version: Int) in
            """
            {"type":"session","version":\(version),"id":"019f9320-d9c6-7bc5-8d94-3cd00ff5e1a8"}
            """
        }
        try write(header(2) + "\n{\"type\":\"message\",\"n\":1}\n")
        var tail = TranscriptTail()
        _ = tail.poll(url)
        let held = tail.offset

        let before = try inode()
        try rewriteInPlace(header(3) + "\n{\"type\":\"message\",\"n\":1}\n")
        XCTAssertEqual(try inode(), before, "in place, same as the migration does it")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(
            UInt64(size ?? -1), held,
            "the whole point: the rewrite has to land on exactly the offset held")

        let batch = tail.poll(url)
        XCTAssertTrue(batch.didReset, "a rewrite nothing follows is still a rewrite")
        XCTAssertEqual(batch.lines.count, 2)
        XCTAssertEqual(
            strings(batch).first?.contains("\"version\":3"), true,
            "and what comes back is the new file, not the old one")
    }

    /// **Control — passes with and without the head guard.** It is what fails if
    /// the guard overshoots: "detect the rewrite" is otherwise satisfied by
    /// resetting on every poll, and a tape that resets four times a second draws
    /// nothing.
    func testAPlainAppendIsNotMistakenForARewrite() throws {
        try write("one\ntwo\n")
        var tail = TranscriptTail()
        _ = tail.poll(url)

        try append("three\n")
        let batch = tail.poll(url)
        XCTAssertFalse(batch.didReset, "an append is an append")
        XCTAssertEqual(strings(batch), ["three"])
    }

    /// **Control for the other overshoot**, and the reason the head is compared
    /// over the bytes both sides have rather than for equality. The first poll
    /// sees 4 bytes and can only remember 4; the next sees a full window. Compared
    /// whole, those differ, and every transcript that started small would reset
    /// itself once on the way past the window.
    func testAFileGrowingPastTheHeadWindowIsNotMistakenForARewrite() throws {
        try write("one\n")
        var tail = TranscriptTail()
        _ = tail.poll(url)

        try append(String(repeating: "x", count: 4_000) + "\n")
        let batch = tail.poll(url)
        XCTAssertFalse(batch.didReset, "the prefix still matches; there are just more bytes now")
        XCTAssertEqual(batch.lines.count, 1)
        XCTAssertEqual(batch.lines.first?.count, 4_000)
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
