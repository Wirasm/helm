import AppKit
import Combine
import Inject
import SwiftUI

// MARK: - Model

/// State for the read-only artifact pane: which file is open, its content, and
/// the watcher that reloads on external change (plans get rewritten by agents
/// while you read them).
///
/// Read-only on purpose — no editing, no commenting. Those are later slices,
/// designed against real dogfooding (see docs/ui-plan.md).
@MainActor
final class ArtifactPaneModel: ObservableObject {
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

    @Published private(set) var document: Document?

    private var watcher: FileWatcher?

    /// Files beyond this are almost certainly not artifacts; refuse instead of
    /// beachballing the pane on a stray binary or log.
    private static let maxBytes = 5_000_000

    var isOpen: Bool { document != nil }

    /// The canvas vertical subscribes to its own command rather than having the
    /// app shell forward it.
    ///
    /// It has to live on the model, not on a view: `helmOpenArtifactFile` exists to
    /// open the pane **while it is closed**, and a receiver attached to the dock
    /// would be torn down in exactly that state. The model outlives the presentation,
    /// so the command lands whether the pane is on screen or not.
    /// An `AnyCancellable` rather than a NotificationCenter token: it unsubscribes in
    /// its own deinit, and Swift 6 forbids a nonisolated deinit from touching the
    /// non-Sendable token the observer API hands back.
    private var openCommand: AnyCancellable?

    init() {
        openCommand =
            NotificationCenter.default
            .publisher(for: .helmOpenArtifactFile)
            .compactMap { $0.object as? URL }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                MainActor.assumeIsolated { self?.open(url) }
            }
    }

    /// The browser's "Browse…" row and the pre-browser ⌘O behavior. Starts at
    /// `directory` when given (a store root), else ~/.prp when it exists — the
    /// intelligence layer's artifact home — else the home directory.
    func presentOpenPanel(startingAt directory: URL? = nil) {
        let panel = NSOpenPanel()
        // Any file is choosable: .md renders formatted, other text renders
        // monospaced, and non-text is refused politely at load time.
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let home = FileManager.default.homeDirectoryForCurrentUser
        let prp = home.appendingPathComponent(".prp")
        panel.directoryURL =
            directory ?? (FileManager.default.fileExists(atPath: prp.path) ? prp : home)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        document = Document(url: url, content: Self.load(url))
        // Reload on every external change. Watcher lifetime == document
        // lifetime; opening another file replaces it.
        watcher = FileWatcher(url: url) { [weak self] in
            self?.reload()
        }
    }

    func close() {
        watcher = nil
        document = nil
    }

    func revealInFinder() {
        guard let url = document?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func reload() {
        guard let previous = document else { return }
        document = Document(
            url: previous.url,
            content: Self.load(previous.url),
            generation: previous.generation + 1
        )
    }

    private static func load(_ url: URL) -> Content {
        // .html renders in a full-pane WKWebView from its own URL — no text
        // pipeline (and no UTF-8/size gate; WebKit streams the file itself).
        if ArtifactHTML.isHTML(url) {
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
        return ArtifactHTML.isMarkdown(url) ? .markdown(text) : .plainText(text)
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

/// The read-only artifact half of the terminal workspace split: a header
/// (filename · reveal-in-Finder · close) over the rendered file.
struct ArtifactPane: View {
    /// Hot reload: `.enableInjection()` below redraws this view when
    /// InjectionNext swaps a recompiled build of it into the running app.
    /// Both are no-ops in release (docs/VENDORED.md).
    @ObserveInjection private var inject
    @ObservedObject var model: ArtifactPaneModel

    var body: some View {
        if let document = model.document {
            VStack(spacing: 0) {
                header(for: document)
                Divider()
                content(for: document)
            }
            .background(Color(nsColor: .textBackgroundColor))
            // Inside the `if`: the body is a bare ViewBuilder conditional with
            // no else, so there is no single view to hang this on outside it.
            .enableInjection()
        }
    }

    @ViewBuilder
    private func content(for document: ArtifactPaneModel.Document) -> some View {
        switch document.content {
        case let .markdown(markdown):
            MarkdownArtifactView(markdown: markdown, generation: document.generation)
        case .web:
            HTMLArtifactView(url: document.url, generation: document.generation)
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

    private func header(for document: ArtifactPaneModel.Document) -> some View {
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
