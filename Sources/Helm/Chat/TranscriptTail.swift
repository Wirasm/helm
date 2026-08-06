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
/// transcript can be replaced under us, and three things are what catch it — a
/// changed inode, a file that shrank, and a changed **head** (#92).
///
/// Deliberately not an actor and deliberately not `@MainActor`: it is a plain
/// value-ish reader with no published state, so the model can own one and call
/// it from wherever it polls.
struct TranscriptTail {
    /// How much of the start of the file is remembered and re-checked.
    ///
    /// Measured on this machine to sit past everything that identifies a
    /// transcript. pi's header line — the record its migration rewrites — runs
    /// 126–334 bytes across 2,281 sessions (median 156), so the window covers
    /// all of it including the trailing `cwd`. Claude Code's first record has a
    /// median of 2,376 bytes across 1,691 transcripts and carries `sessionId`,
    /// `uuid`, `timestamp` and `gitBranch` inside the first 512.
    static let headBytes = 512

    private(set) var offset: UInt64 = 0
    private var inode: UInt64 = 0
    /// The first `headBytes` of the file as last seen — the third guard's whole
    /// state. Short until the file is that long: a transcript's opening poll can
    /// see four bytes, and four bytes is all there is to remember.
    private var head = Data()
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

        // The third guard, and the only one that sees an in-place rewrite ending
        // *longer* than the offset held: same inode, more bytes, so the two above
        // both pass and the read lands mid-record in bytes nobody ever saw (#92).
        // pi writes exactly that shape — `_rewriteFile()` is `openSync(path,
        // "w")`, reached from the pre-v3 migration and from branch/resume.
        //
        // **Charged to the branch that was already opening the file.** A poll
        // with nothing new returns above, having spent one `stat` and no more,
        // which is what keeps the 250 ms cadence free.
        if let fresh = try? handle.read(upToCount: Self.headBytes) {
            if !batch.didReset, !Self.sharesHead(head, fresh) {
                offset = 0
                carry = Data()
                batch.didReset = true
            }
            head = fresh
        }

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

    /// Whether `fresh` still starts with what was remembered.
    ///
    /// **Compared over the bytes both sides have, not for equality**, because a
    /// transcript that was four bytes long on its opening poll could only
    /// remember four — and comparing four against a full window would reset every
    /// short transcript once on the way past `headBytes`. An append never
    /// rewrites what is already there, so a matching common prefix is exactly the
    /// claim "these are the same file, further along".
    ///
    /// **What it cannot see**, said plainly rather than left to be discovered: a
    /// rewrite whose first `headBytes` are byte-identical to the old ones. pi's
    /// two rewrites both change that window — the migration bumps `version`, the
    /// branch mints a new `id`, and both live in a header line under 334 bytes —
    /// but this is a detector, not a proof. The remaining hole is narrower than
    /// the one it closes, and closing it would mean re-reading the file.
    private static func sharesHead(_ remembered: Data, _ fresh: Data) -> Bool {
        let common = min(remembered.count, fresh.count)
        guard common > 0 else { return true }
        return remembered.prefix(common) == fresh.prefix(common)
    }
}
