import SwiftUI
import WebKit

// SECURITY: the WKWebViews in this file render LOCAL artifacts only — mermaid
// diagrams from local markdown, and local .html files opened explicitly by the
// user. No remote content is ever loaded: the navigation delegate cancels
// anything that is not the initially loaded local content, and the only
// JavaScript that runs is the vendored mermaid renderer (docs/VENDORED.md)
// plus the inline init/sizing script from MermaidHTML.

// MARK: - Mermaid island (inline diagram in the markdown flow)

/// One rendered diagram, inline between markdown blocks. Transparent, natural
/// size by default (scrolling horizontally when wider than the pane), and as
/// tall as the rendered SVG: the page posts the SVG's measured height after
/// render (and on reflow) and the island's frame follows, capped by the pane
/// (`maxHeight`) with internal vertical scroll beyond.
///
/// A tiny right-aligned header offers a fit-width ⇄ natural-size toggle and an
/// expand button that opens the diagram in a large zoomable sheet.
struct MermaidIsland: View {
    let diagram: String
    /// Cap from the pane (~70% of its height); `.infinity` when unhosted.
    var maxHeight: CGFloat = .infinity

    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 40
    @State private var fitWidth = false
    @State private var expanded = false
    @State private var expandedSize = CGSize(width: 1000, height: 700)

    private var theme: MermaidTheme { colorScheme == .dark ? .dark : .light }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            controls
            MermaidWebView(
                diagram: diagram,
                theme: theme,
                sizing: fitWidth ? .fitWidth : .natural,
                height: $height
            )
            .frame(height: min(height, maxHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $expanded) {
            MermaidExpandedSheet(diagram: diagram, theme: theme, size: expandedSize)
        }
    }

    /// The island's header row: fit-width toggle + expand, kept visually quiet
    /// so the diagram stays the subject.
    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                fitWidth.toggle()
            } label: {
                Image(systemName: fitWidth
                    ? "arrow.up.left.and.arrow.down.right"
                    : "arrow.down.right.and.arrow.up.left")
            }
            .help(fitWidth ? "Natural size" : "Fit to pane width")
            Button {
                // Size the sheet off the window as it is right now (min 80%).
                if let frame = NSApp.keyWindow?.frame {
                    expandedSize = CGSize(
                        width: max(frame.width * 0.8, 640),
                        height: max(frame.height * 0.8, 480)
                    )
                }
                expanded = true
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Open large view")
        }
        .font(.system(size: 10))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct MermaidWebView: NSViewRepresentable {
    let diagram: String
    let theme: MermaidTheme
    let sizing: MermaidSizing
    @Binding var height: CGFloat

    func makeCoordinator() -> ArtifactWebCoordinator {
        ArtifactWebCoordinator { height = max($0, 1) }
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addMermaidUserScript()
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

    /// Loads only when the (diagram, theme, sizing) triple actually changed —
    /// file-watch re-renders, appearance flips, and fit-width toggles reload;
    /// mere SwiftUI churn does not.
    private func load(_ webView: WKWebView, coordinator: ArtifactWebCoordinator) {
        let key = "\(theme.rawValue)\u{0}\(sizing.rawValue)\u{0}\(diagram)"
        guard coordinator.loadedKey != key else { return }
        coordinator.loadedKey = key
        webView.loadHTMLString(
            MermaidHTML.islandPage(diagram: diagram, theme: theme, sizing: sizing),
            baseURL: nil
        )
    }
}

// MARK: - Expanded diagram sheet

/// The expand button's target: the same diagram at natural size in a large
/// sheet (≥80% of the window when it opened), scrollable both ways and
/// pinch-zoomable via WKWebView magnification.
private struct MermaidExpandedSheet: View {
    let diagram: String
    let theme: MermaidTheme
    let size: CGSize

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Diagram")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            MermaidZoomView(diagram: diagram, theme: theme)
        }
        .frame(minWidth: size.width, minHeight: size.height)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The sheet's web view: natural-size island page, magnification enabled
/// (pinch/⌘-scroll zoom), scrolling handled by the page + web view.
private struct MermaidZoomView: NSViewRepresentable {
    let diagram: String
    let theme: MermaidTheme

    func makeCoordinator() -> ArtifactWebCoordinator {
        // No size handler: the sheet is a fixed viewport, not a sized island.
        // (The page's post guard no-ops when the handler isn't registered.)
        ArtifactWebCoordinator(onHeight: nil)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addMermaidUserScript()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        load(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(webView, coordinator: context.coordinator)
    }

    private func load(_ webView: WKWebView, coordinator: ArtifactWebCoordinator) {
        let key = "\(theme.rawValue)\u{0}\(diagram)"
        guard coordinator.loadedKey != key else { return }
        coordinator.loadedKey = key
        webView.loadHTMLString(
            MermaidHTML.islandPage(diagram: diagram, theme: theme, sizing: .natural),
            baseURL: nil
        )
    }
}

extension WKUserContentController {
    /// Injects the vendored mermaid.js at document start (shared by every
    /// mermaid-rendering web view in this file).
    fileprivate func addMermaidUserScript() {
        guard let mermaidJS = MermaidHTML.vendoredScript() else { return }
        addUserScript(
            WKUserScript(
                source: mermaidJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
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
