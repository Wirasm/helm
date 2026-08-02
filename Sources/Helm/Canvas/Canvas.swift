import AppKit
import Combine
import Inject
import SwiftUI

// MARK: - Model

/// State for the read-only canvas: what it is showing, and the watcher that
/// reloads a file on external change (plans get rewritten by agents while you
/// read them).
///
/// Read-only on purpose — no editing, no commenting. Those are later slices,
/// designed against real dogfooding.
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

    @Published private(set) var showing: Showing?

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

    private var watcher: FileWatcher?

    /// Files beyond this are almost certainly not artifacts; refuse instead of
    /// beachballing the pane on a stray binary or log.
    private static let maxBytes = 5_000_000

    var isOpen: Bool { showing != nil }

    /// The open file, when the canvas is showing one — nil for a URL source.
    /// This is the persistence seam: `WorkspaceModel.saveContext` reads it, so a
    /// URL canvas simply persists nothing rather than a path that is not one.
    var fileURL: URL? {
        if case let .file(document) = showing { document.url } else { nil }
    }

    private var isShowingURL: Bool {
        if case .url = showing { true } else { false }
    }

    /// The canvas vertical subscribes to its own commands rather than having the
    /// app shell forward them.
    ///
    /// They have to live on the model, not on a view: both exist to open the pane
    /// **while it is closed**, and a receiver attached to the dock would be torn
    /// down in exactly that state. The model outlives the presentation, so the
    /// command lands whether the pane is on screen or not.
    /// `AnyCancellable`s rather than NotificationCenter tokens: they unsubscribe in
    /// their own deinit, and Swift 6 forbids a nonisolated deinit from touching the
    /// non-Sendable token the observer API hands back.
    private var commands: Set<AnyCancellable> = []

    init() {
        NotificationCenter.default
            .publisher(for: .helmOpenCanvasFile)
            .compactMap { $0.object as? URL }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                MainActor.assumeIsolated { self?.open(url) }
            }
            .store(in: &commands)

        // ⌘L carries no payload and means "focus the address field"; a URL
        // payload means "open this" — which is what the terminal's ⌘-click on an
        // http link would post if that call site were in this slice.
        NotificationCenter.default
            .publisher(for: .helmOpenCanvasURL)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                MainActor.assumeIsolated {
                    if let url = note.object as? URL {
                        self?.openURL(url)
                    } else {
                        self?.focusAddress()
                    }
                }
            }
            .store(in: &commands)
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
        case let .file(path): open(URL(fileURLWithPath: path))
        case let .url(url): openURL(url)
        case .empty: focusAddress()
        }
    }

    func open(_ url: URL) {
        showing = .file(Document(url: url, content: Self.load(url)))
        // Reload on every external change. Watcher lifetime == document
        // lifetime; opening another file replaces it.
        watcher = FileWatcher(url: url) { [weak self] in
            self?.reload()
        }
    }

    func close() {
        watcher = nil
        showing = nil
    }

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

    var body: some View {
        if let showing = model.showing {
            VStack(spacing: 0) {
                switch showing {
                case let .file(document): header(for: document)
                case let .url(page): CanvasAddressBar(model: model, page: page)
                }
                Divider()
                content(for: showing)
            }
            .background(Color(nsColor: .textBackgroundColor))
            // Inside the `if`: the body is a bare ViewBuilder conditional with
            // no else, so there is no single view to hang this on outside it.
            .enableInjection()
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
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(failure)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary)
                Divider()
            }
            if let url = page.url {
                URLCanvasView(model: model, url: url, generation: page.generation)
            } else {
                Text("Type a URL — localhost:3000")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func fileContent(for document: CanvasModel.Document) -> some View {
        switch document.content {
        case let .markdown(markdown):
            MarkdownCanvasView(markdown: markdown, generation: document.generation)
        case .web:
            HTMLCanvasView(url: document.url, generation: document.generation)
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
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
        }
    }

    private func header(for document: CanvasModel.Document) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(document.url.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(document.url.path)
            Spacer()
            Button {
                model.revealInFinder()
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close artifact")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
