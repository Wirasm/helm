import AppKit
import Inject
import SwiftUI

// MARK: - Model

/// State for the read-only canvas: what it is showing, and the watcher that
/// reloads a file on external change (plans get rewritten by agents while you
/// read them).
///
/// Read-only on the **content**: helm never edits the file, because an agent owns it and
/// rewrites it whole. Commenting is the exception #33 argued for and #39 shipped, and it
/// keeps that rule — a note goes to a sidecar *beside* the canvas (`CanvasNotes`), never
/// into it, precisely so the next rewrite cannot clobber it.
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
    /// `.select` on a SwiftUI churn would look like the canvas ignoring the picker.
    @Published private(set) var markTool: CanvasMarkTool = .select

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
    init(source: CanvasSource? = nil) {
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
        showing = .file(Document(url: url, content: Self.load(url)))
        selection = nil
        notesFailure = nil
        // The drawer is about *this* canvas's sidecar. Carried onto another file it would
        // be open over an artifact whose notes the operator never asked to see.
        showsNotes = false
        // A receipt names the file it was written to. Carried onto a different canvas it is
        // a true sentence about the wrong document, which is worse than no sentence.
        notesNotice = nil
        refreshNotes()
        // Reload on every external change. Watcher lifetime == document
        // lifetime; opening another file replaces it.
        watcher = FileWatcher(url: url) { [weak self] in
            self?.reload()
        }
    }

    /// This pane's canvas is going away. Called by `WorkbenchModel` when the pane closes
    /// — it no longer means "empty the dock", because there is no dock: the ✕ in the
    /// canvas header closes the **pane**, not the source.
    func close() {
        watcher = nil
        showing = nil
    }

    /// What the page's annotation bridge said. A selection puts the comment field over it;
    /// a cleared report — a click on the page that left nothing selected — takes it away,
    /// which is the click-elsewhere-to-dismiss every popover has.
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
    /// reading the page does not require remembering which icon `.select` is.
    func pick(_ tool: CanvasMarkTool) {
        markTool = markTool == tool ? .select : tool
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
            // Written first, copied second, sent third. The sidecar is the memory; the clipboard
            // is a convenience, and a copy that succeeded while the write failed would be a note
            // the operator believes they made and cannot find. Mail is delivery, not storage
            // (#205's acceptance says so in as many words), so it comes last: a mailbox that has
            // gone away must not cost the operator the note itself.
            Pasteboard.copy(CanvasNotes.clipboardEntry(annotation, for: canvas))
            let delivery = onAnnotation?(annotation, canvas) ?? .notSent(.noOrigin)
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

    private func reload() {
        guard case let .file(previous) = showing else { return }
        showing = .file(
            Document(
                url: previous.url,
                content: Self.load(previous.url),
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
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        watch()
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
                self.onChange()
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
            onChange()
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.rearm(attemptsLeft: attemptsLeft - 1)
        }
    }

    deinit {
        source?.cancel()
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

    /// The tools, as chrome on the canvas rather than a mode you have to know about.
    ///
    /// Four small buttons instead of a `Picker`: a segmented control would grow the header
    /// by its own chrome, and this sits beside three existing icon buttons that already
    /// establish the shape.
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

    @ViewBuilder
    private func fileContent(for document: CanvasModel.Document) -> some View {
        switch document.content {
        case let .markdown(markdown):
            MarkdownCanvasView(
                url: document.url, markdown: markdown, generation: document.generation,
                markTool: model.markTool, showsMark: model.showsMark,
                onSelection: model.pageDidReport)
        case .web:
            HTMLCanvasView(
                url: document.url, generation: document.generation,
                markTool: model.markTool, showsMark: model.showsMark,
                onSelection: model.pageDidReport)
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
            markPicker
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
