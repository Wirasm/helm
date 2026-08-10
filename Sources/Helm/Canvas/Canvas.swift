import AppKit
import Inject
import SwiftUI

// MARK: - Model

/// State for the canvas: what it is showing, and the watcher that
/// reloads a file on external change (plans get rewritten by agents while you
/// read them).
///
/// **Read by default, and writable when the operator asks** (#289). Every markdown canvas can be
/// put into a writing face — an agent's plan as much as a note helm started — and `EditableFile`
/// is that line. Nothing enters it by itself: `draft` is nil until the header's Write button is
/// pressed, so reading a canvas is exactly what reading a canvas has always been.
///
/// **Annotations are still a sidecar, and that has not moved.** A comment goes *beside* the canvas
/// (`CanvasNotes`) rather than into it, precisely so the next rewrite cannot clobber it — the
/// exception #33 argued for and #39 shipped. Editing is a different act with a different answer,
/// which is the next paragraph.
///
/// **What happens when an agent rewrites the file under an open draft, which is the question #307
/// deferred.** helm cannot stop the write — an agent writes the file directly, and nothing here is
/// in that path — so what helm guarantees is the other direction: *it never writes over bytes it
/// has not shown the operator, and it never discards his buffer*. `reconcile` compares what is on
/// disk against `draft.saved` — helm's own belief about the file — and when they differ under a
/// dirty draft it raises a `CanvasConflict`, stops saving, and puts the two ways out on a strip.
/// Both are the operator's: `keepMine()` writes his text over theirs, `takeTheirs()` adopts
/// exactly the version he was shown.
@MainActor
final class CanvasModel: ObservableObject {
    /// What the pane shows for the open file: a markdown document (rendered as
    /// one webview — marked + mermaid), a full-pane web view (.html — the
    /// escape hatch; the view loads `Document.url` itself), or plain
    /// monospaced text (everything else, plus load-failure notices).
    enum Content {
        case markdown(String)
        case web
        case plainText(String)
        case notice(String)
    }

    struct Document {
        let url: URL
        var content: Content
        /// Bumped on every external-change reload so the web views reload.
        var generation = 0
    }

    /// A URL the canvas is showing.
    struct Page {
        /// What the address field shows — the committed address, never a
        /// half-typed one.
        var address = ""
        /// What was actually loaded. nil right after ⌘L on a closed canvas:
        /// the field is focused and there is nothing to render yet.
        var url: URL?
        /// A load counter, not a revision: it rises on every navigation *and*
        /// every reload, so re-submitting the address you are already on still
        /// retries. That is the ordinary case — the dev server was not up yet.
        var generation = 0
        /// Why the last load did not render, in the operator's terms. Shown as a
        /// strip above the page rather than instead of it: a refused link must
        /// not throw away what you were looking at.
        var failure: String?
    }

    /// What the canvas is rendering right now — the live half, with the loaded
    /// content, the watcher's generation counter and the last load failure.
    ///
    /// Distinct from `source`, which is the *address* and the only part a bench pane
    /// persists. Splitting them is what lets a URL canvas be restored at all: a value
    /// that carries a `WKWebView`'s navigation state cannot be `Codable`, and one that
    /// carries only an address cannot render.
    enum Showing {
        case file(Document)
        case url(Page)
    }

    @Published private(set) var showing: Showing? {
        didSet {
            if let source { onSourceChange?(source) }
        }
    }

    /// This canvas is now pointed somewhere else — an address was committed, or a page
    /// followed a link.
    ///
    /// The pane's `CanvasSource` is what the bench persists, and it is written **once**,
    /// when the pane is made. ⌘L makes one at `.empty` because at that moment there is no
    /// address; without this hook the URL it goes on to load reaches nothing, and the pane
    /// restores blank however long it was read (#89). `WorkbenchModel` — which owns both
    /// this model and the pane naming it — is what sets this.
    ///
    /// Fired from `showing`'s `didSet` rather than from `openURL`, `submitAddress` and
    /// `pageDidNavigate` one at a time: `source` is a pure function of `showing`, so one
    /// observer catches every move and there is no fourth call site to forget.
    ///
    /// A closure rather than a subscription on `$showing`, because `@Published` fires in
    /// `willSet` — a subscriber reading `source` back would get the value from *before* the
    /// change (`WorkspaceModel.observe` documents that trap and what it cost), and the
    /// main-queue hop that fixes it would make the write-back asynchronous for no gain.
    /// Inside `didSet` the new value is already stored.
    ///
    /// **`showing == nil` is deliberately not reported**, and the non-optional parameter is
    /// what says so. `source` is nil exactly when `showing` is — an emptied canvas is not
    /// pointed anywhere, so there is nothing to hand over. That is the whole reason, and it
    /// holds for every caller of `close()`: the pane-level one in `WorkbenchModel.close`,
    /// which has already dropped the pane, and the two ✕ buttons, which empty the canvas and
    /// leave the pane where it is. Those keep the source they last reported, which is the
    /// right answer while ✕ empties a pane rather than closing it.
    ///
    /// **One writer.** Swift has no access level for "settable by `WorkbenchModel` only", so
    /// this is a plain `var` and overwriting it after `canvas(for:)` has wired it turns the
    /// write-back off silently — which is #89 again, with no compiler to say so.
    var onSourceChange: ((CanvasSource) -> Void)?

    /// Hand a finished mark to whoever can route it, and hear back what happened (#205).
    ///
    /// **A canvas cannot answer "which agent?" and must not try.** Routing needs the terminal that
    /// pushed this canvas, which is bench knowledge — `WorkbenchModel` is the one thing holding
    /// both the pane and the sessions — so this model states the mark and is told the outcome. The
    /// same shape as `onSourceChange` one screen up, and wired in the same place for the same
    /// reason.
    ///
    /// **`nil` is a real, reachable state, not a missing wire.** A `CanvasModel` built outside a
    /// bench has no pane and therefore no origin, so the honest answer is `.notSent(.noOrigin)` —
    /// the clipboard behaviour helm shipped before this existed, and the sentence the operator
    /// sees says exactly that rather than claiming a send.
    var onAnnotation: ((CanvasAnnotation, URL) -> CanvasNoteDelivery)?

    /// Where a note goes when the clipboard is its return path. `Pasteboard.copy` in production.
    ///
    /// **A seam because the operator's pasteboard is not a test fixture.** `PasteboardTests`'s own
    /// header already says it — *"`NSPasteboard.general` is the operator's real clipboard and a test
    /// has no business clearing it"* — and that is doubly true of an assertion that nothing was
    /// written, which needs a known prior value and can only get one by writing first. It is not
    /// hypothetical either: before #303 every run of `CanvasMarkReachesAgentTests` replaced the
    /// operator's clipboard, because `annotate` copies and that suite drives `annotate` for real.
    /// So the sink is injected exactly as `CanvasNoteCourier` injects its `mailboxRoot` and `now`,
    /// for the reason stated there — a test gets one it owns, production takes the default.
    ///
    /// **What it pins is the seam, not the policy.** `CanvasNoteDelivery.copiesToClipboard` is the
    /// rule and is tested as a pure function; this is what lets a test show that `annotate` actually
    /// spends it. #216 is the argument for bothering: a rule and a pipeline were both green for
    /// months while nothing crossed between them.
    var copyToClipboard: (String) -> Void = Pasteboard.copy

    /// Where this canvas is pointed, as the bench persists it.
    var source: CanvasSource? {
        switch showing {
        case let .file(document): .file(document.url)
        // A ⌘L pane with nothing committed is `.empty`, not a URL — restoring it must
        // give back the blank address bar the operator left, not a load of "".
        case let .url(page): page.url.map { CanvasSource.url($0) } ?? .empty
        case nil: nil
        }
    }

    /// Bumped by ⌘L. The address field watches it, which is what lets a second
    /// press re-focus a field that is already on screen.
    @Published private(set) var addressFocus = 0

    // MARK: - Annotation

    /// What the operator has selected on the page and not yet commented on. The bridge
    /// sets it; submitting or dismissing clears it.
    /// Which tool the operator is holding (#112). Lives on the model rather than the view
    /// because it has to survive the pane being rebuilt — a tool that silently reset to
    /// `.read` on a SwiftUI churn would look like the canvas ignoring the picker.
    ///
    /// **`.read` is the default, and it is inert** (#302): a canvas nobody has picked a tool up
    /// on posts nothing at all. Deliberately not persisted, for `showsNotes`' reason one field
    /// down — a canvas that restored still armed would be one the operator did not arm.
    @Published private(set) var markTool: CanvasMarkTool = .read

    /// Whether the sidecar drawer is open (#198). Here for exactly `markTool`'s reason: the
    /// pane is rebuilt on ordinary SwiftUI churn, and a drawer that snapped shut when a
    /// sibling pane redrew would read as helm closing it. It is deliberately **not**
    /// persisted — the drawer is temporary, and a pane that restored with half the artifact
    /// covered would be answering a question nobody asked.
    @Published private(set) var showsNotes = false

    /// A transient "that worked" line. Separate from `notesFailure` because a silent copy is
    /// indistinguishable from a dead click, and because the operator has to know their
    /// clipboard just changed under them.
    @Published private(set) var notesNotice: String?
    private var noticeTask: Task<Void, Never>?

    /// Whether the page should still be holding a mark — a comment is in flight. Named here
    /// rather than recomputed at each call site, since it is the one fact `showsMark` asks
    /// the page about.
    var showsMark: Bool { selection != nil }

    @Published private(set) var selection: CanvasSelection?

    /// The sidecar's whole text, which is what the drawer renders — nil when there is no
    /// sidecar, or nothing but whitespace in it.
    ///
    /// **Stored rather than read where it is drawn.** A view that reads the file in `body`
    /// touches the disk every time SwiftUI redraws it, which for a pane sharing a bench with
    /// live terminals is a great many times a second. One read per refresh, and everything
    /// else about the sidecar is derived from this string rather than read again.
    @Published private(set) var notesText: String?

    /// Every note in this canvas's sidecar, by heading — for the header's `Notes (n)`. Not
    /// tallied in memory: the sidecar IS the memory, and an agent or an editor may have
    /// appended to it since.
    ///
    /// **A pure function of `notesText`**, for `source`'s reason one screen up: a stored
    /// copy is a second call site to forget, and the one it would silently reintroduce is
    /// precisely the disagreement this design exists to prevent — a count taken from one
    /// read of the file beside prose taken from another.
    var notes: [String] { CanvasNotes.headings(in: notesText ?? "") }

    /// Why the last note could not be written, in the operator's terms. Shown in the pane
    /// — a note someone believes they wrote and that went nowhere is worse than one they
    /// were told they could not write.
    @Published private(set) var notesFailure: String?

    // MARK: - Writing in a canvas (#289)

    /// The file this canvas would let the operator write into, when it is showing one at all.
    ///
    /// **nil is the read-only canvas**, and it is nil for an `.html` artifact, for anything helm
    /// renders as plain text, for a `.notes.md` sidecar, and for a URL canvas. `EditableFile`'s
    /// header argues each of those; what matters here is that the writing face is unreachable
    /// without one.
    ///
    /// Computed rather than stored, for `notes`' reason one screen up: a stored copy is a second
    /// thing to keep in step with `showing`, and the canvas can be pointed somewhere else at any
    /// moment.
    var editable: EditableFile? { fileURL.flatMap(EditableFile.init) }

    /// What the operator is typing, and what helm believes is on disk. **nil means reading** —
    /// the rendered page — which is every canvas nobody has pressed Write on, and every one they
    /// have switched back.
    @Published private(set) var draft: CanvasDraft?

    /// Why the file could not be read or written, in the operator's terms.
    ///
    /// **Deliberately not `notesFailure`.** That one is the annotation sidecar's, and the two are
    /// different files with different owners — folding them together would give the operator one
    /// message that could mean either, at the moment they most need to know which.
    @Published private(set) var writeFailure: String?

    /// The save waiting to happen. Cancelled and replaced on every keystroke, so a run of typing
    /// costs one write rather than one per character — `FileWatcher`'s own debounce, from the
    /// other side of the same file.
    private var saveTask: Task<Void, Never>?

    /// How long the file must be quiet before helm writes it.
    ///
    /// **Debounced autosave, and the other two candidates lose work in ways this does not.** An
    /// explicit ⌘S is a thing to remember, and the note it loses is the one taken in a hurry —
    /// which is every note. Save-on-blur only writes when focus moves, and focus does not move
    /// when the machine sleeps, when helm is quit, or when a build takes the operator's attention
    /// for twenty minutes.
    ///
    /// **What it costs, said plainly, and it is worse than "one interval" — that reading was
    /// wrong and a reviewer caught it.** `edit` cancels and reschedules on every keystroke, so
    /// text typed in one continuous burst with no gap this long in it has never been written
    /// **once**: what an unhandled exit loses there is the whole of it, not a bounded tail. That
    /// makes the flush points the load-bearing part rather than the number.
    ///
    /// Every exit helm can see calls `saveDraft()`: switching to Read, closing the pane, pointing
    /// the canvas at another file, closing the last workspace (`WorkbenchModel.deactivate`), and
    /// **quitting** — `WorkbenchModel` subscribes to `NSApplication.willTerminateNotification`
    /// for exactly this reason, because ⌘Q is the ordinary way to leave and reached none of the
    /// others. What remains is `kill -9`, which nothing can cover.
    ///
    /// Long enough that a run of typing is one write rather than one per character, short enough
    /// that a pause between sentences has already saved. Injectable for `FileWatcher`'s reason
    /// one screen down — the tests set their own, so none of them depends on this number.
    private let saveDebounce: Duration

    /// Start writing. The header's Write button, and what a freshly created note opens into.
    ///
    /// **The draft is seeded from disk exactly once, here.** Nothing else seeds it — not the file
    /// watcher, not a re-render, not helm's own save firing that watcher a moment later. The one
    /// exception is `reconcile` adopting a change under a draft with nothing typed into it, which
    /// is the case where there is provably nothing to take away.
    ///
    /// **A file helm cannot read is not opened for writing**, which is the guard that keeps this
    /// from being destructive: seeding an empty draft over an unreadable file and then autosaving
    /// it would replace that file with nothing.
    func write() {
        guard let editable, draft == nil else { return }
        let existing = try? String(contentsOf: editable.url, encoding: .utf8)
        guard let text = existing ?? emptyIfAbsent(editable) else {
            writeFailure =
                "Could not read \(editable.url.lastPathComponent) — helm will not write over a "
                + "file it cannot read."
            return
        }
        writeFailure = nil
        draft = CanvasDraft(text: text, saved: text)
    }

    /// "" for a file that is not there, nil for one that is there and would not read.
    ///
    /// The distinction is the whole of the guard above: a missing file is one helm is about to
    /// create by saving — which is what a note created a moment ago and then deleted looks like —
    /// and an unreadable one is somebody else's bytes.
    private func emptyIfAbsent(_ file: EditableFile) -> String? {
        FileManager.default.fileExists(atPath: file.url.path) ? nil : ""
    }

    /// Stop writing and go back to the rendered page.
    ///
    /// **It refuses while there is text helm could not write**, and that refusal is the point: the
    /// draft is the only copy of those keystrokes, so dropping it to satisfy a button would be the
    /// data loss this whole design is arranged around. The failure strip is already on screen
    /// saying why, and the operator's route out is to fix the file, resolve the conflict, or copy
    /// the text.
    ///
    /// An unresolved conflict is covered by the same line, and by construction rather than by a
    /// second condition: `saveDraft` refuses while one is up, so `isDirty` is still true here.
    func read() {
        saveDraft()
        guard draft?.isDirty != true else { return }
        draft = nil
    }

    /// A keystroke. The one writer of `draft.text`.
    func edit(_ text: String) {
        guard draft != nil else { return }
        draft?.text = text
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDebounce] in
            try? await Task.sleep(for: saveDebounce)
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    /// Write the draft, if there is one and it differs from what is on disk.
    ///
    /// Idempotent and cheap to call, which is what lets every exit path call it rather than
    /// deciding for itself whether a save is owed — `read()`, `open(_:)` and `close()` all do.
    ///
    /// **It refuses while a conflict is up, and that is the whole of "helm does not clobber".**
    /// Somebody else wrote this file since helm last saw it, so writing now would replace bytes
    /// the operator has not been shown. `keepMine()` is the one route through, and it is a button
    /// he presses.
    ///
    /// **A failure keeps the text and says so.** `saved` is not advanced, so `isDirty` stays true,
    /// the next keystroke schedules another attempt, and the editor still holds every character.
    /// A canvas opened through Browse… can live somewhere read-only and `CanvasNotes.append`
    /// already had to say the same thing one method over; this is that rule for the artifact
    /// itself.
    func saveDraft() {
        saveTask?.cancel()
        saveTask = nil
        guard let editable, var draft, draft.isDirty, draft.conflict == nil else { return }
        do {
            try draft.text.write(to: editable.url, atomically: true, encoding: .utf8)
            draft.saved = draft.text
            draft.savedAt = Date()
            self.draft = draft
            writeFailure = nil
        } catch {
            writeFailure =
                "Could not save \(editable.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - When somebody else wrote it too (#289)

    /// The file on disk no longer matches what helm believes it wrote. Decide what that means for
    /// an open draft.
    ///
    /// **`draft.saved` is the whole mechanism**, and it needed no second one: it is *what helm
    /// believes is on disk*, so bytes that differ from it are bytes helm did not put there. Three
    /// outcomes, and the operator loses nothing in any of them:
    ///
    /// - **The same.** helm's own save, firing its own watcher. Nothing happens — which is what
    ///   makes autosave and a live watcher able to share one file at all.
    /// - **Different, and the operator has typed nothing since the last write.** There is provably
    ///   nothing of his to lose, so the change is adopted and he sees the new text. This is the
    ///   ordinary case of reading an agent's plan with the editor open.
    /// - **Different, and he has unsaved text.** A conflict: helm holds their bytes, stops saving,
    ///   and puts both ways out on a strip. Neither direction is decided by helm.
    ///
    /// **Only `.markdown` participates, and the rest is deliberate rather than unhandled.** A file
    /// that has been deleted or has become unreadable loads as `.notice`, and a deletion is not
    /// content to preserve — the draft stays exactly where it is and the next save recreates the
    /// file, which is the same answer `write()` gives for a file that was already absent.
    private func reconcile(_ content: Content) {
        guard case let .markdown(disk) = content, var draft else { return }
        guard disk != draft.saved else {
            // helm and the file agree again. A conflict somebody resolved on disk — by putting
            // back what helm last wrote — has nothing left to refuse, so it is not left up.
            guard draft.conflict != nil else { return }
            draft.conflict = nil
            self.draft = draft
            return
        }
        guard draft.isDirty else {
            draft.text = disk
            draft.saved = disk
            draft.conflict = nil
            self.draft = draft
            return
        }
        // A second write while a conflict is already up replaces it, so the strip is always about
        // the newest bytes helm has seen — and therefore so is what `takeTheirs` adopts.
        draft.conflict = CanvasConflict(theirs: disk)
        self.draft = draft
    }

    /// What the conflict strip says. A property rather than a string built in the view, so the
    /// sentence is reachable from `swift test` and there is one place it is written.
    var conflictNotice: String? {
        guard draft?.conflict != nil, let editable else { return nil }
        return "\(editable.url.lastPathComponent) was rewritten while you were editing — "
            + "helm has stopped saving."
    }

    /// **Keep mine.** Write what is in the editor over what is on disk.
    ///
    /// The operator has been told the file changed and is choosing to replace it. helm does not
    /// re-check first: re-checking would either refuse the button he just pressed or hide a third
    /// version behind it.
    func keepMine() {
        guard draft?.conflict != nil else { return }
        draft?.conflict = nil
        saveDraft()
    }

    /// **Take theirs.** Adopt the version the strip is about, and lose what was typed.
    ///
    /// It adopts the bytes helm *reported*, not the bytes on disk right now — see `CanvasConflict`.
    /// The rendered page is already showing them, because `refresh` re-rendered on the way in.
    func takeTheirs() {
        guard var draft, let conflict = draft.conflict else { return }
        draft.text = conflict.theirs
        draft.saved = conflict.theirs
        draft.conflict = nil
        self.draft = draft
        writeFailure = nil
    }

    // MARK: - An update the page kept (#109)

    /// The artifact was rewritten, the page declined to apply it or broke trying, and helm did
    /// **not** take the page away. nil the rest of the time, which is every page with no update
    /// handler at all — those reload exactly as they always did and there is nothing to say.
    ///
    /// **This is the whole of "offer, don't push" made visible.** The alternative to a strip is
    /// the reload, and the reload is what costs the operator a half-played game; a sentence
    /// above the page costs them one line of it.
    @Published private(set) var updateNotice: String?

    /// The operator pressing Reload, as a counter the view hands down. A counter rather than a
    /// flag for `addressFocus`'s reason: pressing it twice must reload twice, and a flag
    /// consumed asynchronously can be missed.
    @Published private(set) var reloadDemand = 0

    /// What the page said about an offered update. Wired to `HTMLCanvasView` by the view below.
    ///
    /// **`applied` and `unhandled` both clear the strip, and that is not a tidy-up.** A stale
    /// "reload?" over a page that has since taken an update, or over one helm is reloading right
    /// now, is a button that would throw away state for no reason at all.
    func pageAnsweredUpdate(_ answer: CanvasUpdateAnswer) {
        updateNotice = answer.notice
    }

    /// The notice's Reload button — the only thing that reloads a page which said it is holding
    /// state, and it is at the pane by construction.
    func reloadArtifact() {
        updateNotice = nil
        reloadDemand += 1
    }

    // MARK: - What the page said about itself (#110)

    /// The state this pane last wrote to the latch, so an unchanged report costs no write.
    ///
    /// **Not `@Published`, and that is the feature.** A report must move nothing on screen: the
    /// operator is *playing* the page that sent it, and a redraw of the pane around them is the
    /// smallest version of the interruption this whole design exists to avoid. Nothing here is
    /// observable, so nothing redraws.
    ///
    /// Per-pane rather than read back from disk: comparing against the file would mean a read
    /// per report, and the question — *"is this different from what I last wrote?"* — is one
    /// this object is the only writer of.
    ///
    /// **It deliberately survives a reload of the same artifact, and that is not an oversight —
    /// it is what the latch means.** A review read this as a defect (*"the page instance is brand
    /// new, so `writtenAt` must move"*), which is the signal to write the rule down rather than
    /// leave the next reader to re-derive it: **the latch tracks the artifact's state, not the
    /// page's incarnations.** A theme flip, an `unhandled` update and the operator's own Reload
    /// button all destroy the JS context, and a page that comes back reporting exactly what is
    /// already on disk has, by construction, changed nothing. Clearing this there would rewrite
    /// the file to say the same thing and move `writtenAt` — turning the one field an agent
    /// checks for staleness from *"the state last changed"* into *"the page last restarted"*,
    /// which is the reload counter nobody asked for. Pinned by
    /// `CanvasStateTests.testAReloadOfTheSameArtifactIsNotAStateChangeAndWritesNothing`.
    ///
    /// What it is **not** is a claim that the file exists: delete the latch behind helm's back
    /// and an unchanged report will not restore it. That is
    /// `testRepeatingTheSameStateDoesNotRewriteTheLatch`'s instrument rather than a case anybody
    /// is in — helm is the only writer, and re-creating a file somebody deleted on purpose is not
    /// obviously the kinder answer.
    private var latchedState: CanvasStateBody?

    /// **A page reported what it is doing. Write it beside the artifact and stop** (#110).
    ///
    /// Everything this does *not* do is the acceptance: no session woken, no turn started, no
    /// credit spent, no mail sent, no notice raised, nothing published. The agent reads the
    /// latch when it next runs — `CanvasStateLatch`'s header has the standard this is copied
    /// from and why a latch beats an interrupt.
    ///
    /// **An unchanged report is not written**, which is what makes `writtenAt` mean *"the page
    /// last did something different"* rather than *"the page last spoke"*. MCP Apps permits the
    /// dedupe in as many words; `BenchSnapshotModel` already takes the same one for the same
    /// reason, and without it a page reporting on a `requestAnimationFrame` loop would rewrite
    /// the file sixty times a second to say nothing.
    ///
    /// **The honest cost, recorded:** a page whose state genuinely changes every frame gets a
    /// write every frame. That is the page's own choice and helm does not throttle it — a
    /// coalescing delay would make the latch lag exactly when it is moving fastest, which is
    /// the staleness a latch exists to remove.
    func pageDidReportState(_ report: CanvasPageState) {
        guard let canvas = fileURL else { return }
        guard latchedState != report.body else { return }
        do {
            try CanvasStateLatch.write(report.body, for: canvas, at: Date())
            latchedState = report.body
        } catch {
            // **Logged, not swallowed, and deliberately not shown.** The operator did not do
            // this and cannot fix it — an artifact in a directory helm cannot write to is the
            // author's problem, and it is the author who reads `log show`. The bridge's dropped
            // messages are reported the same way, one file over, for the same reason.
            NSLog(
                "helm: could not latch canvas state to "
                    + "\(CanvasStateLatch.sidecarURL(for: canvas).lastPathComponent) — "
                    + error.localizedDescription)
        }
    }

    /// Where this canvas's notes accumulate — beside it, never inside it.
    var sidecarURL: URL? { fileURL.map(CanvasNotes.sidecarURL(for:)) }

    private var watcher: FileWatcher?

    /// Files beyond this are almost certainly not artifacts; refuse instead of
    /// beachballing the pane on a stray binary or log.
    private static let maxBytes = 5_000_000

    var isOpen: Bool { showing != nil }

    /// The open file, when the canvas is showing one — nil for a URL source. What reads it
    /// is live: the header, reveal-in-Finder, and `sidecarURL` (a URL canvas has no file to
    /// write notes beside).
    ///
    /// **It is no longer the persistence seam.** It was — `WorkspaceModel.saveContext` read
    /// `fileURL?.path` into `openArtifactPath`, which is why a URL canvas persisted nothing
    /// at all. The bench persists `CanvasSource` through `Pane.Content.canvas` instead, so
    /// a URL canvas now restores properly and `saveContext` does not read this at all.
    var fileURL: URL? {
        if case let .file(document) = showing { document.url } else { nil }
    }

    private var isShowingURL: Bool {
        if case .url = showing { true } else { false }
    }

    /// **This model no longer subscribes to `openCanvasFile` / `openCanvasURL`,
    /// and must not.** There is one of these per canvas pane now, not one per app: a
    /// subscription here would make every ⌘-clicked link replace the contents of *every*
    /// open canvas at once.
    ///
    /// The reasoning that put those commands on a model rather than a view has not
    /// changed — both exist to open a canvas **while there is none**, and a receiver on a
    /// view would be gone in exactly that state. It moved up one level, to
    /// `WorkbenchModel`, which outlives every canvas pane and is also the thing that now
    /// decides *where* an opened source goes.
    ///
    /// **It no longer takes an artifact root**, which is the seam #289's widening removed rather
    /// than moved: editability used to be a question about where the project stores are, and is
    /// now a question about the file in front of the canvas (`EditableFile`).
    /// - Parameter saveDebounce: how long an edited file must be quiet before helm writes it.
    init(
        source: CanvasSource? = nil,
        saveDebounce: Duration = .milliseconds(600)
    ) {
        self.saveDebounce = saveDebounce
        if let source { show(source) }
    }

    /// The browser's "Browse…" row. Starts at `directory` when given (a store root),
    /// else ~/.prp when it exists — the intelligence layer's artifact home — else the
    /// home directory.
    ///
    /// Returns the choice rather than opening it, and is `static` for the same reason:
    /// picking a file is not something a canvas does to itself any more. Which canvas
    /// shows it — an existing one, a new tab, a new column — is the bench's decision.
    static func chooseFile(startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        // Any file is choosable: .md renders formatted, other text renders
        // monospaced, and non-text is refused politely at load time.
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let home = FileManager.default.homeDirectoryForCurrentUser
        let prp = home.appendingPathComponent(".prp")
        panel.directoryURL =
            directory ?? (FileManager.default.fileExists(atPath: prp.path) ? prp : home)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Point this canvas at a persisted source — the resolve half of `WorkbenchModel`'s
    /// resolve-at-the-edge, and how a restored pane gets back what it was showing.
    func show(_ source: CanvasSource) {
        switch source {
        case let .file(path): open(URL(fileURLWithPath: path.value))
        case let .url(url): openURL(url)
        case .empty: focusAddress()
        }
    }

    func open(_ url: URL) {
        // **Before anything else.** The canvas is being pointed at another file, and the draft
        // belongs to the one it is leaving — a save owed at this moment has nowhere to go once
        // `showing` has moved.
        saveDraft()
        showing = .file(Document(url: url, content: Self.load(url)))
        // The draft is about the file that was here. Carried onto another one it would be the
        // wrong text over the right path, which is the one way an editor destroys work.
        draft = nil
        writeFailure = nil
        selection = nil
        notesFailure = nil
        // The drawer is about *this* canvas's sidecar. Carried onto another file it would
        // be open over an artifact whose notes the operator never asked to see.
        showsNotes = false
        // A receipt names the file it was written to. Carried onto a different canvas it is
        // a true sentence about the wrong document, which is worse than no sentence.
        notesNotice = nil
        // Same rule: "this page is holding state, reload?" is about the page that was here.
        updateNotice = nil
        // The latch belongs to the artifact, not to the pane, so the *file* stays where it is —
        // an agent reads it long after this canvas showed something else. What is dropped is
        // this pane's memory of having written it, because carrying it over would let the first
        // report from the *new* page be deduped against the old one's state and silently not
        // written at all.
        latchedState = nil
        refreshNotes()
        // Reload on every external change to **this file**. Watcher lifetime == document
        // lifetime; opening another file replaces it.
        //
        // **One url, and that is the whole of it.** A sibling the page fetches — `app.js`,
        // `data.json` — is not this file, so rewriting one fires nothing here and the pane
        // keeps rendering what it already had. That is not an oversight to fix by widening
        // the watch: see `refresh()` below, and `WorkbenchModel.offer` (#261), for what a
        // sibling edit does reach the pane through.
        watcher = FileWatcher(url: url) { [weak self] in
            self?.refresh()
        }
    }

    /// This pane's canvas is going away. Called by `WorkbenchModel` when the pane closes
    /// — it no longer means "empty the dock", because there is no dock: the ✕ in the
    /// canvas header closes the **pane**, not the source.
    func close() {
        // The pane is going away and the draft with it, so this is the last moment a save can
        // happen at all. `WorkbenchModel.close` and `closeWorkspace` both reach here, which is
        // every way an editing pane disappears short of the process dying.
        //
        // **Two states leave with it, and helm has no dialog on this path to ask about either**:
        // an unresolved conflict (`saveDraft` refuses, by design) and a write the volume rejected
        // (`writeFailure` is up). Both have had a strip on screen since the moment they happened,
        // which is the whole of the warning the operator gets. Making the close ask would put a
        // modal on a path `helm-close` also reaches, where there is nobody at the pane to answer.
        saveDraft()
        watcher = nil
        showing = nil
    }

    /// What the page's annotation bridge said. A selection puts the comment field over it;
    /// a cleared report — a click on the page that left nothing selected — takes it away,
    /// which is the click-elsewhere-to-dismiss every popover has.
    ///
    /// **What `cleared` still means now that `.read` posts nothing** (#302). It was the one
    /// message a canvas produced without anyone marking, and that is exactly what it has
    /// stopped being — it is now only ever the answer to a gesture made with a tool the
    /// operator picked up. Two live cases, so it is a long way from dead: a `.text` click that
    /// lands away from the selection being commented on, and a `.point` tap that resolves no
    /// target (the page wipes its ring and says so, rather than leaving ink over nothing).
    /// Both are the operator abandoning a mark in flight, which is what this always handled;
    /// what changed is that reading is no longer indistinguishable from that.
    func pageDidReport(_ report: CanvasPageSelection) {
        switch report {
        case let .selected(selection):
            self.selection = selection
            notesFailure = nil
        case .cleared:
            dismissSelection()
            // A click on the page that selected nothing is the click-elsewhere every
            // transient surface closes on, and the drawer is one — it sits *over* the
            // artifact, so wanting to see what is underneath is the ordinary reason to
            // click there. Here rather than in `dismissSelection`, which the comment
            // field's own ✕ and Escape also call: abandoning a comment says nothing about
            // whether the operator still wants the notes up.
            //
            // **Kept, and narrowed by the page rather than by a condition here.** Under
            // `.read` no `cleared` arrives at all, so a drawer no longer closes under a
            // reader's stray click — which is the same complaint as the popup, one surface
            // over, and it is answered where the others are. It still closes for someone
            // who picked a tool up and clicked away, and it keeps its own exits either way.
            closeNotes()
        }
    }

    /// Abandon the annotation in flight: the field's ✕, Escape while it has focus, or a
    /// click on the page that selected nothing.
    ///
    /// **Focus leaving the canvas is deliberately not one of these.** The annotation loop is
    /// canvas → terminal → canvas: reading what the agent said about a passage and coming
    /// back to comment on it is the ordinary path, and dropping the selection — with the
    /// half-typed comment in the field — at exactly that moment would delete work the
    /// operator was in the middle of. So a selection survives a trip to another pane, and
    /// what makes that safe is that **every dismissal above is reachable with a mouse**.
    /// #165 was the other arrangement: one exit, on the responder chain, gone the instant
    /// focus moved, leaving a box that could not be closed at all.
    /// Pick a tool up, or put it down by picking it again. The toggle is a rule rather than
    /// a button's closure, so it is reachable from `swift test` — and so getting back to
    /// reading the page does not require remembering which icon `.read` is.
    ///
    /// **Putting a tool down lands on `.read`, which is now genuinely putting it down** (#302).
    /// It used to land on `.select`, which was still armed for text — so there was no way to
    /// hold nothing at all, and "put it down" meant "swap to the tool you cannot see you are
    /// holding". Picking `.read` itself is a no-op by the same rule, which is the right answer:
    /// asking for the state you are in is not a request to leave it.
    func pick(_ tool: CanvasMarkTool) {
        markTool = markTool == tool ? .read : tool
    }

    /// The Notes button, both ways. The drawer **is** the notes surface — there is no
    /// popover behind it any more — so this is also the only route to `Post` and to
    /// Reveal in Finder for the sidecar.
    func toggleNotes() {
        showsNotes.toggle()
    }

    /// Escape, and the canvas click that reports a cleared selection. Named rather than
    /// written as `showsNotes = false` at each call site, because the two are the same
    /// decision — "put the drawer away" — and a third caller will want it too.
    func closeNotes() {
        showsNotes = false
    }

    /// Whether Escape is the drawer's to take.
    ///
    /// **The comment field takes it first.** #165 put that Escape on the responder chain,
    /// where only the focused field can claim it; the drawer's is a key equivalent, which
    /// fires *before* the first responder is ever asked. Without this rule the drawer would
    /// eat the Escape of someone half-way through typing a comment, and the field they were
    /// trying to abandon would stay exactly where it was.
    var escapeClosesNotes: Bool { showsNotes && selection == nil }

    /// Whether there is a sidecar worth opening — any content beside this canvas, not just
    /// entries helm itself wrote. An agent appending prose with no `##` heading still put
    /// something there to read, and a button that hid it would be the bug this drawer
    /// exists to fix, one level up.
    var hasNotes: Bool { notesText != nil }

    /// Show a notice and take it away again. The timer is deliberately not the operator's
    /// problem: the message is a receipt, not something to dismiss.
    private func announce(_ message: String) {
        notesNotice = message
        // Cancel the previous timer rather than comparing the message. The receipt names the
        // sidecar, so two comments on one file produce byte-identical text — and the first
        // timer would then clear the second one's notice early, which is the ordinary
        // workflow of commenting twice in a row.
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notesNotice = nil
        }
    }

    func dismissSelection() {
        selection = nil
        // The strip explains why the field is still up. Once it is gone the message points
        // at nothing — and "try selecting the text again" names a selection that no longer
        // exists.
        notesFailure = nil
    }

    /// Validation is `CanvasAnnotation.decode`'s, and writing is `CanvasNotes.append`'s.
    /// What is decided here is only what to do when either refuses.
    func annotate(comment: String) {
        guard let canvas = fileURL, let selection else { return }
        guard let annotation = CanvasAnnotation.decode(selection.body, comment: comment) else {
            notesFailure = "That selection could not be anchored — try selecting the text again."
            return
        }
        do {
            try CanvasNotes.append(annotation, for: canvas, at: Date())
            // **Written first, and that is the half of the old ordering that was load-bearing.**
            // The sidecar is the memory; a copy that succeeded while the write failed would be a
            // note the operator believes they made and cannot find. Mail is delivery, not storage
            // (#205's acceptance says so in as many words), so a mailbox that has gone away must
            // not cost the operator the note itself.
            //
            // **"Copied second" could not survive #303, and nothing was resting on it.** Whether to
            // copy now depends on how the note was delivered, and that is not known until the send
            // returns — so the copy moved behind it. The two are independent in both directions:
            // the send never reads the clipboard, and the copy never fed the send. What the old
            // order guaranteed was write-before-copy, and that still holds, one line earlier.
            let delivery = onAnnotation?(annotation, canvas) ?? .notSent(.noOrigin)
            if delivery.copiesToClipboard {
                copyToClipboard(CanvasNotes.clipboardEntry(annotation, for: canvas))
            }
            self.selection = nil
            notesFailure = nil
            announce(
                delivery.receipt(sidecar: CanvasNotes.sidecarURL(for: canvas).lastPathComponent))
            refreshNotes()
        } catch {
            // A canvas opened through Browse… can live anywhere, including somewhere not
            // writable. Say so; never swallow it.
            notesFailure =
                "Could not write \(CanvasNotes.sidecarURL(for: canvas).lastPathComponent): "
                + error.localizedDescription
        }
    }

    func refreshNotes() {
        notesText = sidecarURL.flatMap(CanvasNotes.markdown(in:))
    }

    func revealNotes() {
        guard let sidecar = sidecarURL,
            FileManager.default.fileExists(atPath: sidecar.path)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([sidecar])
    }

    /// The accumulated markdown, for `Post`. nil when there is nothing to hand over — which
    /// is also exactly when the drawer has nothing to render, because it is the same string.
    var notesMarkdown: String? { notesText }

    func revealInFinder() {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Render this file again — and, because a canvas is a page on a real origin, everything
    /// beside it that the page goes on to fetch.
    ///
    /// **Two callers, and they know two different things.** The `FileWatcher` above knows the
    /// artifact changed. `WorkbenchModel.offer` knows an agent pushed this artifact again,
    /// which is the only signal helm gets that a *sibling* changed — nothing watches those
    /// (#261). Neither can tell the other's case apart from a no-op, so both simply ask for a
    /// render and the cost of an unnecessary one is argued where the second call site is.
    ///
    /// Nothing but the generation is guaranteed to move. `Content` is recomputed, but for an
    /// `.html` artifact it is `.web` either way and for a markdown one it is often the same
    /// string — so the counter is what the views key their reload on, and it is what makes
    /// "the bytes on disk changed under an unchanged path" expressible at all.
    ///
    /// A `.url` canvas is deliberately not reachable here: it has no file to re-read, and
    /// `reloadPage()` is the address bar's equivalent.
    ///
    /// **It is also the one place a second writer can be noticed at all** (#289), which is why
    /// `reconcile` hangs here rather than on the watcher: both callers above mean *the bytes may
    /// have changed*, an open draft has to be told either way, and a rule on one of the two
    /// call sites would be absent from the other. The file is read once and the string is handed
    /// to both halves — the render and the reconcile — so they cannot disagree about what is on
    /// disk.
    func refresh() {
        guard case let .file(previous) = showing else { return }
        let content = Self.load(previous.url)
        reconcile(content)
        showing = .file(
            Document(
                url: previous.url,
                content: content,
                generation: previous.generation + 1
            ))
    }

    // MARK: - URL source

    /// Take the canvas to a URL. Single pane: this replaces whatever it was
    /// showing, the same way opening another file does.
    func openURL(_ url: URL) {
        watcher = nil
        showing = .url(
            Page(address: url.absoluteString, url: url, generation: nextGeneration))
    }

    /// ⌘L. On a canvas already showing a page this is "edit this address" and
    /// keeps the page; otherwise it opens an empty one with the field focused.
    func focusAddress() {
        if !isShowingURL {
            watcher = nil
            showing = .url(Page())
        }
        addressFocus += 1
    }

    /// The address field was committed. A refusal keeps the page that is up and
    /// says why, rather than blanking the canvas over a typo.
    func submitAddress(_ typed: String) {
        guard case .url(var page) = showing else { return }
        guard let url = CanvasURLPolicy.address(typed) else {
            page.address = typed
            page.failure =
                "Not an address the canvas can open: "
                + typed.trimmingCharacters(in: .whitespacesAndNewlines)
            showing = .url(page)
            return
        }
        openURL(url)
    }

    func reloadPage() {
        guard case .url(var page) = showing, page.url != nil else { return }
        page.generation += 1
        page.failure = nil
        showing = .url(page)
    }

    /// The page navigated itself — a link, a redirect. The address follows it, so
    /// the field never lies about what is on screen and reload reloads what you
    /// are looking at.
    func pageDidNavigate(to url: URL) {
        guard case .url(var page) = showing else { return }
        page.address = url.absoluteString
        page.url = url
        page.failure = nil
        showing = .url(page)
    }

    func pageDidFail(_ message: String) {
        guard case .url(var page) = showing else { return }
        page.failure = message
        showing = .url(page)
    }

    private var nextGeneration: Int {
        if case let .url(page) = showing { page.generation + 1 } else { 0 }
    }

    private static func load(_ url: URL) -> Content {
        // .html renders in a full-pane WKWebView from its own URL — no text
        // pipeline (and no UTF-8/size gate; WebKit streams the file itself).
        if RenderableFile.isHTML(url) {
            return .web
        }
        guard let data = try? Data(contentsOf: url) else {
            return .notice("Could not read \(url.path)")
        }
        guard data.count <= maxBytes else {
            return .notice("File too large to display (\(data.count / 1_000_000) MB)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .notice("Not a UTF-8 text file")
        }
        return RenderableFile.isMarkdown(url) ? .markdown(text) : .plainText(text)
    }
}

// MARK: - File watcher

/// DispatchSource-based watcher for a single file. Editors and agents replace
/// files atomically (write-to-temp + rename), which fires `.rename`/`.delete`
/// on the OLD inode and silently orphans the file descriptor — so on those
/// events the watcher re-opens the path (briefly retrying while the writer
/// finishes) and keeps watching the NEW inode.
///
/// **Every notification is debounced, and a partial write is the reason** (#109). `.write` and
/// `.extend` fire per *write*, not per *save*: a writer that does not replace the file
/// atomically — `>` in a shell, a `FileHandle`, an agent streaming a long document — produces
/// one event per chunk, and each one used to re-read the file and re-render it. So the operator
/// watched a truncated page render, then a longer truncated page, then the real one. Coalescing
/// them into one call, a beat after the writing stops, is the whole fix: nothing renders while
/// the bytes are still arriving, and one save is one render.
///
/// **The atomic path is debounced too, even though it has no partial state to hide.** A rename
/// arrives whole, so it could notify immediately — but then a save that is *sometimes* atomic
/// (many editors write in place for small files and rename for large ones) would have two
/// different latencies, and "did helm see my write?" would have two different answers. One
/// funnel, one answer.
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private let debounce: Duration
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?

    /// - Parameter debounce: how long the file must be quiet before a change is reported.
    ///   Long enough to swallow the chunks of one write, short enough that a save still feels
    ///   immediate — a rendered page arriving 120ms after the agent's last byte is not
    ///   something an operator can perceive as a delay, and the tests set their own so they
    ///   never depend on this number.
    init(
        url: URL, debounce: Duration = .milliseconds(120),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
        watch()
    }

    /// Report a change once the file has been quiet for `debounce`. Each new event cancels the
    /// one waiting, so a run of writes reports **once**, after the last of them.
    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }

    private func watch() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.rename) || event.contains(.delete) {
                // Old inode gone (atomic save). Rearm on the path, then render.
                self.source?.cancel()
                self.source = nil
                self.rearm(attemptsLeft: 5)
            } else {
                self.schedule()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// The replacement file may not exist for a moment mid-rename; retry a few
    /// times before giving up (the pane then just keeps its last render).
    private func rearm(attemptsLeft: Int) {
        if FileManager.default.fileExists(atPath: url.path) {
            watch()
            schedule()
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.rearm(attemptsLeft: attemptsLeft - 1)
        }
    }

    deinit {
        source?.cancel()
        // The pane is gone; a render scheduled a moment ago has nothing left to render into.
        pending?.cancel()
    }
}

// MARK: - View

/// The read-only canvas half of the terminal workspace split: a header over the
/// rendered source. Which header is the source's own — a file gets its filename
/// and reveal-in-Finder, a URL gets an address bar.
struct CanvasView: View {
    /// Hot reload: `.enableInjection()` below redraws this view when
    /// InjectionNext swaps a recompiled build of it into the running app.
    /// Both are no-ops in release (docs/VENDORED.md).
    @ObserveInjection private var inject
    @ObservedObject var model: CanvasModel
    /// Hands the accumulated notes to a composer. The bench decides which one — there may
    /// be several chat faces open, and an unaddressed notification would prefill them all.
    var post: ((String) -> Void)?

    var body: some View {
        if let showing = model.showing {
            VStack(spacing: 0) {
                switch showing {
                case let .file(document): header(for: document)
                case let .url(page): CanvasAddressBar(model: model, page: page)
                }
                Divider()
                // Its own `if`, not an arm of the chain below: an update helm is holding back
                // and a note that failed to write are unrelated facts about different things,
                // and either hiding the other would be helm choosing which of the operator's
                // problems they are allowed to see.
                if let update = model.updateNotice {
                    updateStrip(update)
                }
                // Its own `if`, for the reason given directly above. This one asks rather than
                // reports, so it is the second strip carrying buttons — and it is above the write
                // failure deliberately: a conflict is *why* nothing is being written, so a
                // failure under it would be the symptom above the cause.
                if let conflict = model.conflictNotice {
                    conflictStrip(conflict)
                }
                // Its own `if`, for the reason given directly above: an edit that would not save
                // and a comment that would not write are facts about two different files, and
                // hiding either behind the other is helm choosing which of the operator's
                // problems they are allowed to see.
                if let failure = model.writeFailure {
                    noticeStrip(failure, symbol: "exclamationmark.triangle")
                }
                if let failure = model.notesFailure {
                    noticeStrip(failure, symbol: "exclamationmark.triangle")
                } else if let notice = model.notesNotice {
                    noticeStrip(notice, symbol: "checkmark.circle")
                }
                content(for: showing)
                    // Over the artifact, never squeezing it: the page keeps its layout and
                    // its scroll position, and the drawer is temporary.
                    .overlay(alignment: .trailing) { notesDrawer }
                    .animation(.easeOut(duration: 0.16), value: model.showsNotes)
                    // The comment field is drawn over the page rather than beside it, so
                    // the selection it is about stays visible under it. **After** the
                    // drawer, so it is on top of one: a mark on the trailing half puts the
                    // field over the drawer, and the field is the thing being typed into.
                    .overlay(alignment: .topLeading) { commentField }
            }
            .background(Color.surface)
            // Inside the `if`: the body is a bare ViewBuilder conditional with
            // no else, so there is no single view to hang this on outside it.
            .enableInjection()
        }
    }

    /// The sidecar over the trailing half of the pane. Sized from the pane it is over
    /// rather than from a fixed number, by `CanvasNotesDrawerMetrics`.
    ///
    /// A URL canvas has no sidecar to show, so `sidecarURL` is the second half of the
    /// condition — `showsNotes` alone would put an empty drawer over a web page.
    @ViewBuilder
    private var notesDrawer: some View {
        if model.showsNotes, model.sidecarURL != nil {
            GeometryReader { proxy in
                CanvasNotesDrawer(model: model, post: post)
                    .frame(
                        width: CanvasNotesDrawerMetrics.width(inPaneOf: proxy.size.width),
                        height: proxy.size.height
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Anchored near the selection the page reported, clamped so a selection at the
    /// bottom of a long document does not put the field off screen.
    @ViewBuilder
    private var commentField: some View {
        if let selection = model.selection {
            CanvasCommentField(model: model, selection: selection)
                .offset(
                    x: max(8, selection.rect.minX),
                    y: max(8, selection.rect.maxY + 8))
        }
    }

    /// The one strip that carries an action. Everything else helm says above a canvas is a
    /// receipt — this is a question, because the answer costs the operator their page.
    private func updateStrip(_ message: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise.circle")
                Text(message).lineLimit(2)
                Spacer()
                Button("Reload") { model.reloadArtifact() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accent)
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.surfaceRaised)
            Divider()
        }
    }

    /// The second strip that carries actions, and the only one that carries two (#289).
    ///
    /// **Both buttons cost the operator something, so both are his to press and neither is
    /// default-styled into looking safe.** helm has already refused to write; what is left is a
    /// choice it has no standing to make — whether an agent's rewrite or his own half-sentence is
    /// the one that survives. The tooltips say which is which in full, because "Keep mine" and
    /// "Take theirs" are only unambiguous when read together.
    private func conflictStrip(_ message: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                Text(message).lineLimit(2)
                Spacer()
                Button("Keep mine") { model.keepMine() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accent)
                    .help("Write what you have typed over the version on disk")
                Button("Take theirs") { model.takeTheirs() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accent)
                    .help("Load the version on disk and lose what you have typed")
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.surfaceRaised)
            Divider()
        }
    }

    private func noticeStrip(_ message: String, symbol: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(message).lineLimit(2)
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.surfaceRaised)
            Divider()
        }
    }

    /// Write ⇄ Read, on a markdown canvas.
    ///
    /// **Read is the state it starts in, and Write is a press.** That is the operator's own line
    /// — *"there should be a read mode and editor mode, default is read"* — and it is why an
    /// editable canvas is indistinguishable from a read-only one until he asks.
    ///
    /// Accent while writing, the same way a held tool and an open drawer already say which way
    /// they are pointing — one treatment for "this control is on", spent at a third site rather
    /// than a third treatment invented for it.
    private var writeToggle: some View {
        Button {
            if model.draft == nil { model.write() } else { model.read() }
        } label: {
            Text(model.draft == nil ? "Write" : "Read")
                .font(.system(size: 11))
                .frame(minWidth: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.draft == nil ? Color.textMuted : Color.accent)
        .help(model.draft == nil ? "Edit this file" : "Render this file")
    }

    /// The tools, as chrome on the canvas rather than a mode you have to know about.
    ///
    /// Five small buttons instead of a `Picker`: a segmented control would grow the header
    /// by its own chrome, and this sits beside three existing icon buttons that already
    /// establish the shape.
    ///
    /// **`.read` is in the picker rather than implied by nothing being lit** (#302), and it is
    /// the one that starts lit. A mode with no button is a mode the operator cannot see they
    /// are in — and it is the only tool that is put down by picking it, so leaving it out
    /// would also mean the only route back to reading is knowing that pressing the held tool
    /// again does it.
    private var markPicker: some View {
        HStack(spacing: 2) {
            ForEach(CanvasMarkTool.allCases, id: \.self) { tool in
                Button {
                    model.pick(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 11))
                        .frame(width: 20, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(model.markTool == tool ? Color.selection : .clear))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.markTool == tool ? Color.accent : Color.textMuted)
                .help(tool.help)
            }
        }
    }

    @ViewBuilder
    private func content(for showing: CanvasModel.Showing) -> some View {
        switch showing {
        case let .file(document): fileContent(for: document)
        case let .url(page): urlContent(for: page)
        }
    }

    /// The URL source. The failure is a strip above the page rather than a
    /// replacement for it: a refused link must not cost you the page you were
    /// reading, and a dead dev server should say so instead of showing WebKit's
    /// blank white pane.
    @ViewBuilder
    private func urlContent(for page: CanvasModel.Page) -> some View {
        VStack(spacing: 0) {
            if let failure = page.failure {
                noticeStrip(failure, symbol: "exclamationmark.triangle")
            }
            if let url = page.url {
                URLCanvasView(model: model, url: url, generation: page.generation)
            } else {
                Text("Type a URL — localhost:3000")
                    .foregroundStyle(Color.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The writing face, when there is an editable file and the operator is in it.
    ///
    /// **Ahead of `document.content` rather than a case inside it**, because a draft is about the
    /// file and not about what helm made of its bytes: a file the operator has emptied loads as
    /// `.markdown("")` and one that has just been deleted under them loads as `.notice`, and
    /// switching them out of the editor on either would drop what they were typing.
    @ViewBuilder
    private func fileContent(for document: CanvasModel.Document) -> some View {
        if let editable = model.editable, let draft = model.draft {
            CanvasEditorView(model: model, file: editable, draft: draft)
        } else {
            renderedContent(for: document)
        }
    }

    @ViewBuilder
    private func renderedContent(for document: CanvasModel.Document) -> some View {
        switch document.content {
        case let .markdown(markdown):
            MarkdownCanvasView(
                url: document.url, markdown: markdown, generation: document.generation,
                markTool: model.markTool, showsMark: model.showsMark,
                onSelection: model.pageDidReport)
        case .web:
            // The only canvas that can take an update as data: an `.html` artifact is read
            // straight from disk, so its own scripts run and one of them may be
            // `window.helmCanvasUpdate`. A markdown canvas is a page helm *generates* —
            // `marked` writes the artifact into `innerHTML`, where a `<script>` never executes
            // — so there is no author's code on it to register a handler, and it reloads
            // exactly as it always has.
            HTMLCanvasView(
                url: document.url, generation: document.generation,
                markTool: model.markTool, showsMark: model.showsMark,
                onSelection: model.pageDidReport,
                reloadDemand: model.reloadDemand, onUpdate: model.pageAnsweredUpdate,
                onState: model.pageDidReportState)
        case let .plainText(text):
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case let .notice(message):
            Text(message)
                .foregroundStyle(Color.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
        }
    }

    private func header(for document: CanvasModel.Document) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(Color.textMuted)
            // **The name is the handle to the file, so it hands the file over.** What you
            // most often want from an open canvas is where it is — to pass to an agent, to
            // paste into a shell — and the path was already here as a tooltip, which is a
            // thing you can read and not take. The tooltip stays and the click is added.
            CopyableLabel(
                value: Pasteboard.path(of: document.url),
                hint: "Click to copy \(Pasteboard.path(of: document.url))"
            ) {
                Text(document.url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            // **Only on a markdown file, which is the visible half of the scope line.** An
            // `.html` artifact, a plain-text file and a sidecar have no Write button at all —
            // there is nothing to click and nothing to explain.
            if model.editable != nil {
                writeToggle
            }
            // Nothing to mark while writing: the page is not on screen, and a picker over a text
            // editor would be four buttons that do nothing.
            if model.draft == nil {
                markPicker
            }
            // Attention as state on an existing element, never a popup: a count on the
            // header, not a badge that pops. It is a toggle now rather than a popover's
            // anchor, and it says which way it is pointing — accent while the drawer is
            // open, the same way a held tool does.
            //
            // Shown for **any** sidecar, not only one with `##` entries in it: the count is
            // helm's own notes, but an agent appending plain prose beside the canvas still
            // put something there to read, and hiding the only way in would be this issue
            // over again.
            if model.hasNotes {
                Button {
                    model.toggleNotes()
                } label: {
                    Text(model.notes.isEmpty ? "Notes" : "Notes (\(model.notes.count))")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.showsNotes ? Color.accent : Color.textMuted)
                .help("The comments written beside this canvas")
            }
            Button {
                model.revealInFinder()
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textMuted)
            .help("Reveal in Finder")
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textMuted)
            .help("Close artifact")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(Color.textPrimary)
        .background(ChromeBackground())
    }
}
