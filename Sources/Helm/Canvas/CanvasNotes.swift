import Foundation

/// The return path: comments accumulate BESIDE the canvas, never inside it — the agent
/// rewrites the canvas and would clobber anything written into it (#33).
///
/// `~/.prp/<key>/canvas/tasks.html` → `~/.prp/<key>/canvas/tasks.notes.md`
///
/// The sidecar is itself a `.md` file the artifact browser will list, and that is wanted:
/// the notes are an artifact, and the operator should be able to open them.
enum CanvasNotes {
    /// What makes a filename a sidecar rather than a document.
    ///
    /// **Named once, because a second reader appeared** (#289). It used to be spelled inline in
    /// `sidecarURL` below and nothing else had to know it; now `OperatorNote` does, and asking
    /// here rather than restating `".notes.md"` there is what keeps the two from drifting.
    static let sidecarSuffix = ".notes.md"

    /// `plan.md` → `plan.notes.md`, `tasks.html` → `tasks.notes.md`, `README` →
    /// `README.notes.md`. Beside the canvas, whatever directory that is.
    static func sidecarURL(for canvas: URL) -> URL {
        let name = canvas.deletingPathExtension().lastPathComponent
        return canvas.deletingLastPathComponent()
            .appendingPathComponent("\(name)\(sidecarSuffix)")
    }

    /// Whether this file is some canvas's sidecar rather than a document of its own.
    ///
    /// **The question `OperatorNote` has to ask, and the reason it exists** (#289). A sidecar is
    /// written *beside* its canvas, so a note's sidecar lands in `notes/` — where it is a `.md`
    /// file, three components under the artifact root, and therefore indistinguishable from a
    /// note by shape alone. Letting it pass for one would put the writing face over it, and
    /// `CanvasModel.saveNote` **overwrites**, which is precisely what `append` below says must
    /// never happen to this file: *"the sidecar is the memory; a rewrite would lose earlier
    /// notes"*. So the exclusion is not tidiness — it is that sentence enforced from the one
    /// place that could otherwise break it.
    static func isSidecar(_ url: URL) -> Bool {
        // Any case: `plan.NOTES.md` is the same file on a case-insensitive volume, and benchd
        // refuses to write it whole whatever it is called (`bench_wire::is_notes_sidecar`).
        url.lastPathComponent.lowercased().hasSuffix(sidecarSuffix)
    }

    /// One entry, in the shape an agent reads without being taught anything: the anchor as
    /// a heading, the comment as prose, the time as a footnote.
    static func entry(_ annotation: CanvasAnnotation, at timestamp: Date) -> String {
        let heading = "## " + describe(annotation.mark)
        return """
            \(heading)

            \(annotation.comment)

            <sub>\(stamp(timestamp))</sub>

            """
    }

    /// The mark as a heading an agent reads without being taught anything: the anchor.
    ///
    /// Historical geometry headings remain readable but cannot become a current mark.
    static func describe(_ mark: CanvasAnnotation.Mark) -> String {
        switch mark {
        case let .selection(anchor): name(anchor)
        }
    }

    /// Parse the exact heading format we write, not arbitrary operator prose.
    static func mark(in heading: String) -> CanvasAnnotation.Mark? {
        if heading.hasPrefix("`#"), let boundary = heading.range(of: "` — ") {
            let id = String(
                heading[heading.index(heading.startIndex, offsetBy: 2)..<boundary.lowerBound])
            guard let text = headingText(String(heading[boundary.upperBound...])) else {
                return nil
            }
            guard
                CanvasAnnotation.Mark.decode(["id": id, "text": text], as: .selection)
                    == .selection(.element(id: id, text: text))
            else { return nil }
            return .selection(.element(id: id, text: text))
        }
        guard let text = headingText(heading) else { return nil }
        guard
            CanvasAnnotation.Mark.decode(["text": text], as: .selection)
                == .selection(.quote(text))
        else { return nil }
        return .selection(.quote(text))
    }

    struct Note: Identifiable {
        let id: Int
        let heading: String
        let text: String
        var mark: CanvasAnnotation.Mark? { CanvasNotes.mark(in: heading) }
    }

    /// Keep the full entry, including its comment and timestamp, under one hover target.
    static func entries(in text: String) -> [Note] {
        var entries: [Note] = []
        var lines: [String] = []
        var heading = ""
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if !lines.isEmpty {
                    entries.append(
                        Note(
                            id: entries.count, heading: heading, text: lines.joined(separator: "\n")
                        ))
                }
                heading = String(line.dropFirst(3))
                lines = [line]
            } else {
                lines.append(line)
            }
        }
        if !lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.append(
                Note(id: entries.count, heading: heading, text: lines.joined(separator: "\n")))
        }
        return entries
    }

    /// The anchor with its text, for a mark about one thing.
    private static func name(_ anchor: CanvasAnnotation.Anchor) -> String {
        switch anchor {
        case let .element(id, text): "`#\(id)` — \(quoted(text))"
        case let .quote(text): quoted(text)
        }
    }

    /// What goes on the clipboard when a comment is written, so it can be pasted straight
    /// into an agent that helm cannot reach.
    ///
    /// **The same line the sidecar writes, plus the path** — not a second format. The heading
    /// already carries the anchor and the text it covered, which is how an agent verifies it
    /// resolved to the right thing. Byte-identical to the file means a paste and the sidecar
    /// can never disagree.
    ///
    /// **One comment, never the accumulation.** Pasting every note is the same as pasting the
    /// file, and the canvas header already copies the path for that. And no image: an anchor
    /// made of pixels is not something an agent can edit, which is the whole reason it is an
    /// id. That is a fact about this payload and not a rule about screenshots (#39).
    static func clipboardEntry(_ annotation: CanvasAnnotation, for canvas: URL) -> String {
        """
        canvas: \(canvas.path)

        \(describe(annotation.mark))

        \(annotation.comment)
        """
    }

    /// **Append, never rewrite.** The sidecar is the memory; a rewrite would lose earlier
    /// notes and race the operator, who may have the file open.
    ///
    /// Throws rather than swallowing: a directory that cannot be written to has to be
    /// surfaced in the pane. A note the operator believes they wrote and that went nowhere
    /// is worse than a note they were told they could not write.
    ///
    /// Written by benchd (`file/append`), which also refuses any whole-file write to a sidecar,
    /// so "append, never rewrite" holds at the verb boundary and not only here.
    static func append(
        _ annotation: CanvasAnnotation, for canvas: URL, at timestamp: Date,
        through files: any CanvasFiles
    ) throws {
        try files.append(entry(annotation, at: timestamp), to: sidecarURL(for: canvas).path)
    }

    /// Every entry's heading, for the pane's `Notes (n)` count. Takes the sidecar's text
    /// rather than its URL so the count and the drawer's rendering are carved out of one
    /// read of one file — two reads could disagree, and then the header would be counting
    /// notes the drawer is not showing.
    ///
    static func headings(in text: String) -> [String] {
        entries(in: text).map(\.heading).filter { !$0.isEmpty }
    }

    /// The sidecar as the drawer reads it: the file's own text, with the timestamp's `<sub>`
    /// wrapper taken off.
    ///
    /// **The one liberty the drawer takes, and it is presentation.** `entry` writes the
    /// stamp as `<sub>…</sub>` because the sidecar is read by agents and by whatever renders
    /// markdown-with-HTML — helm's own document canvas does, through marked. The drawer shows
    /// plain text, so the tags would sit there as literal angle brackets in the one surface
    /// built to make this file legible. Dropping them costs no interpretation of the note
    /// itself — the heading is left exactly as written, which is the boundary #199 needs held.
    static func readable(_ text: String) -> String {
        text.replacingOccurrences(of: "<sub>", with: "")
            .replacingOccurrences(of: "</sub>", with: "")
    }

    /// The whole accumulation, or nil when the sidecar is missing or blank — or could not be
    /// read, which is logged: the drawer has nothing true to show either way, and the notes
    /// themselves are safe on benchd's side.
    static func markdown(in sidecar: URL, through files: any CanvasFiles) -> String? {
        let read = files.read(sidecar.path, within: nil)
        if case let .failed(why) = read {
            NSLog("helm: could not read \(sidecar.lastPathComponent) — \(why)")
        }
        return markdown(from: read)
    }

    /// The same, from a read already made.
    static func markdown(from read: CanvasFileRead) -> String? {
        guard case let .bytes(data) = read, let text = CanvasText.decode(data),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Simple headings keep their original spelling. An explicit `text` prefix distinguishes
    /// escaped JSON from historical raw quotes (whose backslashes were literal).
    private static func quoted(_ text: String) -> String {
        if !text.contains(where: { $0.isNewline || $0 == "\"" || $0 == "\\" || $0 == "\t" }) {
            return "\"\(text)\""
        }
        let data = try! JSONEncoder().encode(text)
        return "text " + String(decoding: data, as: UTF8.self)
    }

    private static func headingText(_ heading: String) -> String? {
        if heading.hasPrefix("text ") {
            return try? JSONDecoder().decode(String.self, from: Data(heading.dropFirst(5).utf8))
        }
        guard heading.hasPrefix("\""), heading.hasSuffix("\""), heading.count >= 2 else {
            return nil
        }
        return String(heading.dropFirst().dropLast())
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
