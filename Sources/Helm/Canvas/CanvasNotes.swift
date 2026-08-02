import Foundation

/// The return path: comments accumulate BESIDE the canvas, never inside it — the agent
/// rewrites the canvas and would clobber anything written into it (#33).
///
/// `~/.prp/<key>/canvas/tasks.html` → `~/.prp/<key>/canvas/tasks.notes.md`
///
/// The sidecar is itself a `.md` file the artifact browser will list, and that is wanted:
/// the notes are an artifact, and the operator should be able to open them.
enum CanvasNotes {
    /// `plan.md` → `plan.notes.md`, `tasks.html` → `tasks.notes.md`, `README` →
    /// `README.notes.md`. Beside the canvas, whatever directory that is.
    static func sidecarURL(for canvas: URL) -> URL {
        let name = canvas.deletingPathExtension().lastPathComponent
        return canvas.deletingLastPathComponent().appendingPathComponent("\(name).notes.md")
    }

    /// One entry, in the shape an agent reads without being taught anything: the anchor as
    /// a heading, the comment as prose, the time as a footnote.
    static func entry(_ annotation: CanvasAnnotation, at timestamp: Date) -> String {
        let heading =
            switch annotation.anchor {
            case let .element(id, text): "## `#\(id)` — \"\(singleLine(text))\""
            case let .quote(text): "## \"\(singleLine(text))\""
            }
        return """
            \(heading)

            \(annotation.comment)

            <sub>\(stamp(timestamp))</sub>

            """
    }

    /// **Append, never rewrite.** The sidecar is the memory; a rewrite would lose earlier
    /// notes and race the operator, who may have the file open.
    ///
    /// Throws rather than swallowing: a directory that cannot be written to has to be
    /// surfaced in the pane. A note the operator believes they wrote and that went nowhere
    /// is worse than a note they were told they could not write.
    static func append(_ annotation: CanvasAnnotation, for canvas: URL, at timestamp: Date) throws {
        let url = sidecarURL(for: canvas)
        let text = entry(annotation, at: timestamp)
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Every entry's heading, for the pane's `Notes (n)` count and list. Reading the file
    /// rather than keeping a parallel tally: the sidecar is the memory, and something else
    /// may have appended to it.
    static func headings(in sidecar: URL) -> [String] {
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("## ") }
            .map { String($0.dropFirst(3)) }
    }

    /// The whole accumulation, for `Post`.
    static func markdown(in sidecar: URL) -> String? {
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Newlines out of a heading — a multi-line selection would otherwise break the
    /// markdown structure the agent is meant to read.
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
