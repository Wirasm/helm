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
    /// monospaced, for a sidecar, and for a URL canvas (which has no file to be asked about).
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
