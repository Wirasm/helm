import SwiftUI
import WebKit

// SECURITY: the WKWebViews in this file render LOCAL artifacts only — markdown
// documents converted client-side, and local .html files opened explicitly by
// the user. No remote content is ever loaded: the navigation delegate cancels
// anything that is not the initially loaded local content, and the only
// JavaScript that runs is the vendored marked + mermaid (docs/VENDORED.md)
// plus the inline scripts from CanvasHTML.

// MARK: - Markdown artifact (one webview per document)

/// A whole markdown artifact as a single WKWebView: CanvasHTML.documentPage
/// carries the source, marked converts it in the page, mermaid renders its
/// fences. Magnification is on — pinch/⌘-scroll zooms the whole document.
/// `generation` bumps on external file change to force a plain reload.
struct MarkdownCanvasView: View {
    let markdown: String
    let generation: Int

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MarkdownCanvasWebView(
            markdown: markdown,
            generation: generation,
            theme: colorScheme == .dark ? .dark : .light
        )
    }
}

private struct MarkdownCanvasWebView: NSViewRepresentable {
    let markdown: String
    let generation: Int
    let theme: CanvasTheme

    func makeCoordinator() -> CanvasFileCoordinator {
        CanvasFileCoordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Vendored renderers arrive as user scripts at document start; the
        // page's inline script then only converts and renders.
        for script in [CanvasHTML.vendoredMarked(), CanvasHTML.vendoredMermaid()] {
            guard let script else { continue }
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        load(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(webView, coordinator: context.coordinator)
    }

    /// Loads only when the (theme, generation, content) triple actually
    /// changed — file-watch reloads and appearance flips re-render; mere
    /// SwiftUI churn does not.
    private func load(_ webView: WKWebView, coordinator: CanvasFileCoordinator) {
        let key = "\(theme.rawValue)\u{0}\(generation)\u{0}\(markdown)"
        guard coordinator.loadedKey != key else { return }
        coordinator.loadedKey = key
        webView.loadHTMLString(
            CanvasHTML.documentPage(markdown: markdown, theme: theme),
            baseURL: nil
        )
    }
}

// MARK: - Full-pane .html artifact

/// The escape hatch for .html artifacts: the whole pane is one WKWebView
/// loading the local file (read access limited to the file's directory).
/// The vendored mermaid.js + an init script are injected so
/// `<pre class="mermaid">` blocks render without the page shipping its own
/// renderer. `generation` bumps on external file change to force a reload.
struct HTMLCanvasView: View {
    let url: URL
    let generation: Int

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HTMLCanvasWebView(
            url: url,
            generation: generation,
            theme: colorScheme == .dark ? .dark : .light
        )
    }
}

private struct HTMLCanvasWebView: NSViewRepresentable {
    let url: URL
    let generation: Int
    let theme: CanvasTheme

    func makeCoordinator() -> CanvasFileCoordinator {
        CanvasFileCoordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        load(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(webView, coordinator: context.coordinator)
    }

    /// (Re)loads when the file, its generation (external change), or the theme
    /// changes. Scripts are re-armed per load so a theme flip re-renders the
    /// page's diagrams in the matching mermaid theme.
    private func load(_ webView: WKWebView, coordinator: CanvasFileCoordinator) {
        let key = "\(theme.rawValue)\u{0}\(generation)\u{0}\(url.path)"
        guard coordinator.loadedKey != key else { return }
        coordinator.loadedKey = key

        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if let mermaidJS = CanvasHTML.vendoredMermaid() {
            controller.addUserScript(
                WKUserScript(
                    source: mermaidJS,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
            controller.addUserScript(
                WKUserScript(
                    source: CanvasHTML.htmlArtifactInitScript(theme: theme),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }
        // Local file access only: read access is limited to the artifact's
        // own directory (for its relative images/CSS), nothing beyond.
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}

// MARK: - Shared coordinator

/// Navigation policy for both artifact web views. Local-only enforcement lives
/// here: any navigation that is not local content (the document's about:blank
/// HTML string, the artifact's file: URL) is cancelled — a link in a document
/// or an .html page's remote reference goes nowhere.
@MainActor
final class CanvasFileCoordinator: NSObject, WKNavigationDelegate {
    var loadedKey: String?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        if let url, url.isFileURL || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}
