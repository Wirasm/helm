import Foundation

/// A file the canvas will let the operator write into (#289).
///
/// **This is the scope line, and it is a different line from the one #307 shipped.** That build
/// answered *"which files are editable?"* with `OperatorNote` — a markdown file at exactly
/// `<artifact root>/<key>/notes/<name>.md` — because the second half of #289 needed an answer to
/// the question `CanvasNotes` avoided, and only the note-taking half had one. The operator has
/// since ruled on that question: *"normally when working on a plan I will mark it and ask the
/// agent to update it, I rarely will rewrite manually more than a sentence or two"*. So **every
/// markdown canvas is editable**, and the conflict answer is built rather than dodged —
/// `CanvasConflict` and `CanvasModel.reconcile` are it.
///
/// **Markdown, because the other renderer is a different piece of work and the issue says so.**
/// An `.html` canvas is served to a `WKWebView` and the artifact's own JavaScript runs, so an
/// editor there is a web app rather than a text view. A markdown canvas is a page helm *generates*
/// — the source is the file, byte for byte, so editing it is the identity operation.
///
/// **A `.notes.md` sidecar is excluded, and that exclusion survives the widening on its own
/// merits.** `CanvasNotes.append` only ever appends, because the sidecar is the memory of every
/// comment made on that canvas; the editor overwrites, so one keystroke in one would replace the
/// lot. Asked of `CanvasNotes` rather than spelled here, so the two cannot drift.
///
/// **Standardized, because `Workbench.pane(showing:)` compares sources by value.** Holding a
/// `StandardizedPath` rather than a `URL` composes the two invariants instead of restating one:
/// `/a/./x.md` and `/a/x.md` are one editable file here for the same reason they are one canvas
/// pane there (#88).
///
/// **What it is *not* is a claim about ownership or about writability.** An agent may rewrite this
/// file at any moment — that is the whole of what `CanvasConflict` exists for — and the volume may
/// refuse the write, which `CanvasModel.writeFailure` has always reported. The type answers one
/// question only: may helm put a text editor over these bytes at all.
struct EditableFile: Equatable {
    /// The file itself.
    let path: StandardizedPath

    var url: URL { URL(fileURLWithPath: path.value) }

    /// Recognise one by its path — the only route in.
    ///
    /// nil for an `.html` artifact, for plain text and every other extension the canvas renders
    /// monospaced, and for a sidecar.
    /// Each of those is read-only, which is what it was before this existed.
    ///
    /// **No artifact root, and that is the widening made visible.** The old rule needed to know
    /// where the project stores were, so `CanvasModel` carried one; this rule is about the file
    /// in front of it, so the canvas no longer has to be told where `~/.prp` is at all.
    init?(_ url: URL) {
        guard RenderableFile.isMarkdown(url) else { return nil }
        guard !CanvasNotes.isSidecar(url) else { return nil }
        path = StandardizedPath(url)
    }
}

// MARK: - What is actually there

extension EditableFile {
    /// What is on disk right now, as far as benchd can tell helm.
    ///
    /// **Three cases because a read has three outcomes, and collapsing two of them is a clobber.**
    /// The first version of the pre-write check in `CanvasModel.saveDraft` was
    /// `if let disk = try? String(contentsOf:…), disk != draft.saved` — which makes *"the read
    /// failed"* land in the same branch as *"the file is what I left there"*, and falls through
    /// to the write. helm then replaced bytes it had never managed to look at, with no strip and
    /// no notice: the exact clobber `CanvasConflict` exists to prevent, reached through the check
    /// built to close it.
    ///
    /// **It is reachable, and there are more ways in now.** An agent streaming a long document
    /// non-atomically leaves a torn multi-byte sequence for a read that lands mid-write; a writer
    /// saving in Latin-1 or UTF-16 makes a complete file that is simply not UTF-8; and with the
    /// file on benchd's side (M5c), benchd not answering is a read that told helm nothing at all.
    ///
    /// So the type carries the distinction, and every reader has to say what it does about not
    /// knowing.
    enum DiskContents: Equatable {
        /// Read and decoded. These are the bytes, and they can be compared.
        case bytes(String)
        /// Nothing is there. **Not an unknown**: there is nothing to protect, and a save creates
        /// the file — which is what a note deleted under the operator, and one `write()` seeded
        /// empty, both depend on.
        case absent
        /// Present and not text helm can show, or not readable at all — the words say which. The
        /// only case with no safe default: helm does not know what is there.
        case unreadable(String)
    }

    /// Ask benchd for the file.
    func contents(through files: any CanvasFiles) -> DiskContents {
        switch files.read(path.value, within: nil) {
        case let .bytes(data):
            guard let text = CanvasText.decode(data) else {
                return .unreadable("it is not UTF-8 text")
            }
            return .bytes(text)
        case .absent: return .absent
        case .outside: return .unreadable("benchd answered for a folder nobody named")
        case let .failed(why): return .unreadable(why)
        }
    }
}
