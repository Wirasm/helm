import Foundation

/// Byte-offset tailing of one append-only JSONL transcript.
///
/// **Why this is safe, measured rather than assumed** (#29's reader half, 860
/// appends / 9.1 MB): every append ended on a newline, zero torn lines, zero
/// truncations, zero inode changes — including a single 720 KB append carrying
/// nine records. So resuming from a byte offset and consuming to the last
/// newline is correct, and the carry buffer is the only discipline it needs.
///
/// The offset is held against the **path**, not an open file descriptor: a
/// transcript can be replaced under us, and `(inode, size)` is what catches it.
///
/// Deliberately not an actor and deliberately not `@MainActor`: it is a plain
/// value-ish reader with no published state, so the model can own one and call
/// it from wherever it polls.
struct TranscriptTail {
    private(set) var offset: UInt64 = 0
    private var inode: UInt64 = 0
    /// The bytes after the last newline of the previous read — a record that was
    /// still being written. Measured never to happen, kept because the cost of
    /// being wrong is a dropped record and the cost of the buffer is nothing.
    private var carry = Data()

    /// What one poll produced.
    struct Batch {
        /// Complete JSONL lines, in file order.
        var lines: [Data] = []
        /// The file was replaced or truncated — everything read before this
        /// batch is stale and the caller must start its own state over.
        var didReset = false
    }

    /// Read whatever has been appended since the last call.
    ///
    /// Returns an empty batch when there is nothing new, which is the common
    /// case: a turn opens with a median 8.83 s of no bytes at all.
    mutating func poll(_ url: URL) -> Batch {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return Batch() }

        var batch = Batch()
        let node = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        // A new file, or one that shrank: a full reparse is affordable (13.4 MB
        // / 6,210 records measured at 43 ms) and is the only correct answer.
        if node != inode || size < offset {
            offset = 0
            carry = Data()
            inode = node
            batch.didReset = true
        }
        guard size > offset else { return batch }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return batch }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return batch }
        offset += UInt64(chunk.count)

        let newline = UInt8(0x0A)
        carry.append(chunk)
        guard let lastNewline = carry.lastIndex(of: newline) else { return batch }
        let complete = Data(carry[carry.startIndex...lastNewline])
        carry = Data(carry[carry.index(after: lastNewline)...])

        batch.lines =
            complete
            .split(separator: newline, omittingEmptySubsequences: true)
            .map { Data($0) }
        return batch
    }
}
