import SwiftUI
import WebKit

// SECURITY: the WKWebViews in this file render LOCAL artifacts only — mermaid
// diagrams from local markdown, and local .html files opened explicitly by the
// user. No remote content is ever loaded: the navigation delegate cancels
// anything that is not the initially loaded local content, and the only
// JavaScript that runs is the vendored mermaid renderer (docs/VENDORED.md)
// plus the inline init/sizing script from MermaidHTML.

// MARK: - Mermaid island (inline diagram in the markdown flow)

/// One rendered diagram, inline between markdown blocks. Transparent, scaled
/// to the pane width, and exactly as tall as the rendered diagram: the page
/// posts its content height after render (and on reflow) and the island's
/// frame follows.
struct MermaidIsland: View {
    let diagram: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 40

    var body: some View {
        MermaidWebView(
            diagram: diagram,
            theme: colorScheme == .dark ? .dark : .light,
            height: $height
        )
        .frame(height: height)
    }
}

private struct MermaidWebView: NSViewRepresentable {
    let diagram: String
    let theme: MermaidTheme
    @Binding var height: CGFloat

    func makeCoordinator() -> ArtifactWebCoordinator {
        ArtifactWebCoordinator { height = max($0, 1) }
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let mermaidJS = MermaidHTML.vendoredScript() {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: mermaidJS,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }
        configuration.userContentController.add(
            context.coordinator, name: MermaidHTML.sizeHandlerName
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Transparent island: the native pane's background shows through
        // (paired with `background: transparent` in the page's CSS).
        webView.setValue(false, forKey: "drawsBackground")
        load(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onHeight = { height = max($0, 1) }
        load(webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: ArtifactWebCoordinator) {
        // The content controller retains its message handlers; break the cycle.
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: MermaidHTML.sizeHandlerName)
    }

    /// Loads only when the (diagram, theme) pair actually changed — file-watch
    /// re-renders and appearance flips reload; mere SwiftUI churn does not.
    private func load(_ webView: WKWebView, coordinator: ArtifactWebCoordinator) {
        let key = "\(theme.rawValue)\u{0}\(diagram)"
        guard coordinator.loadedKey != key else { return }
        coordinator.loadedKey = key
        webView.loadHTMLString(
            MermaidHTML.islandPage(diagram: diagram, theme: theme),
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
struct HTMLArtifactView: View {
    let url: URL
    let generation: Int

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HTMLArtifactWebView(
            url: url,
            generation: generation,
            theme: colorScheme == .dark ? .dark : .light
        )
    }
}

private struct HTMLArtifactWebView: NSViewRepresentable {
    let url: URL
    let generation: Int
    let theme: MermaidTheme

    func makeCoordinator() -> ArtifactWebCoordinator {
        ArtifactWebCoordinator(onHeight: nil)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        load(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(webView, coordinator: context.coordinator)
    }

    /// (Re)loads when the file, its generation (external change), or the theme
    /// changes. Scripts are re-armed per load so a theme flip re-renders the
    /// page's diagrams in the matching mermaid theme.
    private func load(_ webView: WKWebView, coordinator: ArtifactWebCoordinator) {
        let key = "\(theme.rawValue)\u{0}\(generation)\u{0}\(url.path)"
        guard coordinator.loadedKey != key else { return }
        coordinator.loadedKey = key

        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if let mermaidJS = MermaidHTML.vendoredScript() {
            controller.addUserScript(
                WKUserScript(
                    source: mermaidJS,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
            controller.addUserScript(
                WKUserScript(
                    source: MermaidHTML.htmlArtifactInitScript(theme: theme),
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

/// Navigation policy + height messages for both artifact web views. Local-only
/// enforcement lives here: any navigation that is not local content (the
/// island's about:blank HTML string, the artifact's file: URL) is cancelled —
/// a diagram link or an .html page's remote reference goes nowhere.
@MainActor
final class ArtifactWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var onHeight: ((CGFloat) -> Void)?
    var loadedKey: String?

    init(onHeight: ((CGFloat) -> Void)?) {
        self.onHeight = onHeight
    }

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

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let height = message.body as? Double else { return }
        onHeight?(CGFloat(height))
    }
}
