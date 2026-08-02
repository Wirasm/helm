import SwiftUI
import WebKit

// SECURITY: the WKWebViews in this file render LOCAL artifacts only — markdown
// documents converted client-side, and local .html files opened explicitly by
// the user. No remote content is ever loaded: the navigation delegate cancels
// anything that is not the initially loaded local content, and the only
// JavaScript that runs is the vendored marked + mermaid (docs/VENDORED.md)
// plus the inline scripts from CanvasHTML — which now include the ANNOTATION
// BRIDGE, a script message handler the page can post to.
//
// The bridge is why `CanvasBridgePolicy` exists and why this file is separate
// from URLCanvasViews.swift. A handler on a webview that loads arbitrary
// websites would let any page post into helm, so it is installed here, on local
// artifacts only, and each webview gets its OWN WKUserContentController — the
// controller is a property of the configuration, so one shared instance would
// share every registered script and handler with every webview, which is
// exactly how the bridge would reach the URL source by accident.

// MARK: - Markdown artifact (one webview per document)

/// A whole markdown artifact as a single WKWebView: CanvasHTML.documentPage
/// carries the source, marked converts it in the page, mermaid renders its
/// fences. Magnification is on — pinch/⌘-scroll zooms the whole document.
/// `generation` bumps on external file change to force a plain reload.
struct MarkdownCanvasView: View {
    let markdown: String
    let generation: Int
    /// What the operator selected on the page, for the comment field to anchor to.
    let onSelection: (CanvasSelection) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MarkdownCanvasWebView(
            markdown: markdown,
            generation: generation,
            theme: colorScheme == .dark ? .dark : .light,
            onSelection: onSelection
        )
    }
}

private struct MarkdownCanvasWebView: NSViewRepresentable {
    let markdown: String
    let generation: Int
    let theme: CanvasTheme
    let onSelection: (CanvasSelection) -> Void

    func makeCoordinator() -> CanvasFileCoordinator {
        CanvasFileCoordinator(onAnnotation: onSelection)
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
        context.coordinator.installBridge(on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        load(webView, coordinator: context.coordinator)
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: CanvasFileCoordinator) {
        coordinator.removeBridge(from: webView.configuration.userContentController)
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
    let onSelection: (CanvasSelection) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HTMLCanvasWebView(
            url: url,
            generation: generation,
            theme: colorScheme == .dark ? .dark : .light,
            onSelection: onSelection
        )
    }
}

private struct HTMLCanvasWebView: NSViewRepresentable {
    let url: URL
    let generation: Int
    let theme: CanvasTheme
    let onSelection: (CanvasSelection) -> Void

    func makeCoordinator() -> CanvasFileCoordinator {
        CanvasFileCoordinator(onAnnotation: onSelection)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        context.coordinator.installBridge(on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        load(webView, coordinator: context.coordinator)
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: CanvasFileCoordinator) {
        coordinator.removeBridge(from: webView.configuration.userContentController)
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
        // `removeAllUserScripts` takes the annotation script with it, so it is re-added
        // below. Forgetting that is how annotation would silently die the first time the
        // operator switched appearance.
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
        coordinator.addAnnotationScript(to: controller)
        // Local file access only: read access is limited to the artifact's
        // own directory (for its relative images/CSS), nothing beyond.
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}

// MARK: - Shared coordinator

/// Navigation policy for both artifact web views, plus the annotation bridge's plumbing —
/// and nothing but plumbing. What the page sent is validated by `CanvasAnnotation.decode`,
/// which is pure and testable; a `WKScriptMessage` is not.
///
/// Local-only enforcement lives here: any navigation that is not local content (the
/// document's about:blank HTML string, the artifact's file: URL) is cancelled — a link in
/// a document or an .html page's remote reference goes nowhere.
@MainActor
final class CanvasFileCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var loadedKey: String?
    private let onAnnotation: (CanvasSelection) -> Void
    private lazy var proxy = WeakScriptMessageProxy(self)

    init(onAnnotation: @escaping (CanvasSelection) -> Void) {
        self.onAnnotation = onAnnotation
    }

    func installBridge(on controller: WKUserContentController) {
        controller.add(proxy, name: CanvasBridgePolicy.handlerName)
        addAnnotationScript(to: controller)
    }

    func addAnnotationScript(to controller: WKUserContentController) {
        controller.addUserScript(
            WKUserScript(
                source: CanvasHTML.annotationScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
    }

    /// Called from `dismantleNSView`, and that is the only place it can work from.
    /// `add(_:name:)` retains the handler **strongly** and the controller is reachable
    /// from the webview, so relying on the handler's own `deinit` cannot work — the cycle
    /// is precisely what stops `deinit` firing. The weak proxy and this call are both
    /// needed; neither alone is reliable.
    func removeBridge(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: CanvasBridgePolicy.handlerName)
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

    /// WebKit delivers script messages on the main thread, which is what makes
    /// `assumeIsolated` correct here rather than a hop that would let a second selection
    /// overtake the first.
    nonisolated func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let selection = CanvasSelection(message.body) else { return }
            onAnnotation(selection)
        }
    }
}

// MARK: - What the page reported

/// A live selection on the canvas: the payload the comment field needs, before there is a
/// comment to make an annotation out of.
///
/// `body` stays raw so `CanvasAnnotation.decode` — the pure, tested validation — is the
/// one thing that ever interprets it. This carries only what the UI needs to place itself.
struct CanvasSelection {
    /// The untrusted body, handed to `CanvasAnnotation.decode` once there is a comment.
    let body: [String: Any]
    /// Where the selection is in the viewport, so the field can be anchored near it.
    /// Presentation only; never persisted, and never part of an anchor.
    let rect: CGRect

    init?(_ body: Any) {
        guard let payload = body as? [String: Any] else { return nil }
        self.body = payload
        let raw = payload["rect"] as? [String: Any] ?? [:]
        func number(_ key: String) -> CGFloat {
            CGFloat((raw[key] as? NSNumber)?.doubleValue ?? 0)
        }
        rect = CGRect(
            x: number("x"), y: number("y"), width: number("width"), height: number("height"))
    }
}

// MARK: - WeakScriptMessageProxy

/// Stands between `WKUserContentController` and the real handler, holding it weakly.
///
/// `add(_:name:)` retains its handler strongly, and the controller is retained by the
/// configuration, which is retained by the webview — so handler → model → webview closes
/// a cycle and the whole pane leaks. This breaks it.
@MainActor
final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var handler: (any WKScriptMessageHandler)?

    init(_ handler: any WKScriptMessageHandler) {
        self.handler = handler
    }

    nonisolated func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            handler?.userContentController(controller, didReceive: message)
        }
    }
}
