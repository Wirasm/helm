import CanvasKit
import HelmWire
import PocketKit
import SwiftUI
import WebKit

/// pages: a search field, then each workspace's plan and review pages as a section that
/// collapses, last edited first.
struct PagesView: View {
    @EnvironmentObject private var model: PocketModel
    @State private var refused: String?
    @State private var query = ""
    /// The collapsed sections' paths (`Collapsed`): kept across launches, apart from the chats'.
    @AppStorage("collapsedPages") private var collapsedPaths = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $query, prompt: Text("search").foregroundStyle(Palette.faint))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(Mono.body).foregroundStyle(Palette.text)
                .padding(.horizontal, 16).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.pages.compactMap { $0.matching(query) }) { section in
                        let open = !Collapsed.has(section.path, collapsedPaths) || !query.isEmpty
                        SectionHeader(name: section.name, open: open, count: section.pages.count) {
                            collapsedPaths = Collapsed.toggling(section.path, collapsedPaths)
                        }
                        if open {
                            ForEach(section.pages) { page in
                                NavigationLink {
                                    PageView(page: page)
                                } label: {
                                    PageRow(page: page, opened: model.isOpened(page))
                                }
                            }
                        }
                    }
                    if let refused {
                        Text(refused).font(Mono.small).foregroundStyle(Palette.asking)
                    } else if model.pages.isEmpty {
                        Text("no pages").font(Mono.small).foregroundStyle(Palette.faint)
                    }
                }
                .padding(.horizontal, 16)
            }
            .refreshable { refused = await model.loadPages()?.description }
        }
        .task(id: model.workspaces) { refused = await model.loadPages()?.description }
    }
}

/// One page: ● when an agent opened it on the bench and a reply reaches it, its age.
struct PageRow: View {
    let page: PocketPage
    let opened: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(opened ? "●" : "○").foregroundStyle(opened ? Palette.finished : Palette.faint)
            Text(page.title).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.head)
            Spacer()
            Text(BenchSessionRow.age(sinceMs: page.modifiedMs, now: Date()))
                .foregroundStyle(Palette.dim)
        }
        .font(Mono.body)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// One page, rendered from its bytes as helm renders a canvas, and the operator's reply under it.
/// A reply goes into the page's live file, and benchd mails it to the agent that opened the page;
/// a page no agent opened has nobody to mail, so it says so instead of offering to.
struct PageView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    let page: PocketPage
    @State private var reply = ""
    @State private var sending = false
    @State private var said: String?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("‹") { dismiss() }.foregroundStyle(Palette.dim)
                Text(page.title).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.head)
            }
            .font(Mono.body)
            if let files = model.files {
                // A new connection is a new page: the old benchd's files are not this one's.
                CanvasWebView(path: page.path, files: files, failed: $failed)
                    .id(model.endpoint?.description)
            }
            if let failed { Text(failed).font(Mono.small).foregroundStyle(Palette.asking) }
            if let said { Text(said).font(Mono.small).foregroundStyle(Palette.dim) }
            if model.isOpened(page) {
                replyBox
            } else {
                Text("no agent opened this page on the bench: a reply would reach nobody")
                    .font(Mono.small).foregroundStyle(Palette.faint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var replyBox: some View {
        HStack {
            TextField("", text: $reply, prompt: Text("reply…").foregroundStyle(Palette.faint))
                .textInputAutocapitalization(.never)
                .onSubmit(send)
            Button("↑", action: send)
                .foregroundStyle(sending ? Palette.faint : Palette.finished)
                .disabled(sending)
        }
        .font(Mono.body)
        .foregroundStyle(Palette.text)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }

    /// One reply at a time; the text stays until benchd took it.
    private func send() {
        let text = reply
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            if let refused = await model.reply(text, to: page) {
                said = refused.description
                if refused.maybeSent, reply == text { reply = "" }
            } else {
                said = "replied"
                if reply == text { reply = "" }
            }
            sending = false
        }
    }
}

/// helm's canvas page in a web view: `CanvasSchemeHandler` serves the page and its siblings from
/// benchd's file verbs on the page's own `helm-canvas://` origin, and `CanvasDataChannel` lets the
/// page's script write its live file, as helm's HTML canvas does.
struct CanvasWebView: UIViewRepresentable {
    let path: String
    let files: any CanvasFiles
    /// Why the page did not load, for the view to say: a page benchd could not read is a failed
    /// navigation and an empty web view otherwise.
    @Binding var failed: String?

    func makeCoordinator() -> Coordinator { Coordinator(failed: $failed) }

    /// Says why a navigation failed, and clears it when one finishes.
    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var failed: String?

        init(failed: Binding<String?>) { _failed = failed }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { failed = nil }

        func webView(
            _ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) { failed = "could not read the page: \(error.localizedDescription)" }

        func webView(
            _ view: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
        ) { failed = "could not read the page: \(error.localizedDescription)" }
    }

    func makeUIView(context: Context) -> WKWebView {
        let artifact = URL(fileURLWithPath: path)
        let standardized = StandardizedPath(path)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            CanvasSchemeHandler(artifact: artifact, files: files) { files.document(artifact) },
            forURLScheme: CanvasAddress.scheme)
        if let live = BenchLiveFile.path(for: path) {
            let channel = CanvasDataChannel(host: CanvasAddress.host(for: standardized)) {
                write in
                files.writeLive(write, to: live)
            }
            configuration.userContentController.addScriptMessageHandler(
                channel, contentWorld: .page, name: CanvasDataWrite.handlerName)
        }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.navigationDelegate = context.coordinator
        if let url = CanvasAddress.url(for: standardized) { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
