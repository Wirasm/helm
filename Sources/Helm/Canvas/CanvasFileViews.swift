import SwiftUI
import WebKit

// SECURITY: the WKWebViews in this file render LOCAL artifacts only — markdown
// documents converted client-side, and local .html files opened explicitly by
// the user. No remote content is ever loaded: the navigation delegate cancels
// anything that is not this artifact's own helm-canvas:// origin, and the only
// JavaScript that runs is the vendored marked + mermaid (docs/VENDORED.md)
// plus the inline scripts from CanvasHTML — which include the ANNOTATION
// BRIDGE, a script message handler the page can post to.
//
// The bridge is why `CanvasBridgePolicy` exists and why this file is separate
// from URLCanvasViews.swift. A handler on a webview that loads arbitrary
// websites would let any page post into helm, so it is installed here, on local
// artifacts only, and each webview gets its OWN WKUserContentController — the
// controller is a property of the configuration, so one shared instance would
// share every registered script and handler with every webview, which is
// exactly how the bridge would reach the URL source by accident.
//
// ADDRESSING (#108): each artifact is served on its own `helm-canvas://<host>`
// origin by `CanvasSchemeHandler`, so a message carries which canvas sent it
// (`CanvasAddress.accepts`). The bridge lives in a NAMED CONTENT WORLD, so the
// page's own JavaScript cannot see `window.webkit.messageHandlers` at all —
// only helm's injected script, which runs in that same world, can post.

// MARK: - Markdown artifact (one webview per document)

/// A whole markdown artifact as a single WKWebView: CanvasHTML.documentPage
/// carries the source, marked converts it in the page, mermaid renders its
/// fences. Magnification is on — pinch/⌘-scroll zooms the whole document.
/// `generation` bumps on external file change to force a plain reload.
struct MarkdownCanvasView: View {
    /// The artifact this page is, which is what gives it an addressable origin.
    let url: URL
    let markdown: String
    let generation: Int
    /// What the operator selected on the page, for the comment field to anchor to — and
    /// when they clicked away and selected nothing, which is what takes the field down.
    let onSelection: (CanvasPageSelection) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MarkdownCanvasWebView(
            url: url,
            markdown: markdown,
            generation: generation,
            theme: colorScheme == .dark ? .dark : .light,
            onSelection: onSelection
        )
    }
}

private struct MarkdownCanvasWebView: NSViewRepresentable {
    let url: URL
    let markdown: String
    let generation: Int
    let theme: CanvasTheme
    let onSelection: (CanvasPageSelection) -> Void

    private var path: StandardizedPath { StandardizedPath(url) }

    func makeCoordinator() -> CanvasFileCoordinator {
        CanvasFileCoordinator(host: CanvasAddress.host(for: path), onAnnotation: onSelection)
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
        // The page is generated, not on disk, so the handler serves whatever the
        // coordinator last staged — which is what keeps a theme flip and a file change
        // rendering the current document rather than the one this view was built with.
        let coordinator = context.coordinator
        configuration.setURLSchemeHandler(
            CanvasSchemeHandler(artifact: URL(fileURLWithPath: path.value)) {
                [weak coordinator] in coordinator?.stagedDocument
            },
            forURLScheme: CanvasAddress.scheme
        )
        coordinator.installBridge(on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.allowsMagnification = true
        load(webView, coordinator: coordinator)
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
        coordinator.stagedDocument = Data(
            CanvasHTML.documentPage(markdown: markdown, theme: theme).utf8)
        guard let address = CanvasAddress.url(for: path) else { return }
        webView.load(URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData))
    }
}

// MARK: - Full-pane .html artifact

/// The escape hatch for .html artifacts: the whole pane is one WKWebView
/// serving the local file from its own origin (siblings in the artifact's
/// directory resolve; nothing outside it does). The vendored mermaid.js + an
/// init script are injected so `<pre class="mermaid">` blocks render without
/// the page shipping its own renderer. `generation` bumps on external file
/// change to force a reload.
struct HTMLCanvasView: View {
    let url: URL
    let generation: Int
    let onSelection: (CanvasPageSelection) -> Void

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
    let onSelection: (CanvasPageSelection) -> Void

    private var path: StandardizedPath { StandardizedPath(url) }

    func makeCoordinator() -> CanvasFileCoordinator {
        CanvasFileCoordinator(host: CanvasAddress.host(for: path), onAnnotation: onSelection)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let artifact = URL(fileURLWithPath: path.value)
        // Read straight from disk per request: the artifact IS the document here, and a
        // reload is meant to show what the agent just wrote.
        configuration.setURLSchemeHandler(
            CanvasSchemeHandler(artifact: artifact) {
                try? Data(contentsOf: artifact)
            },
            forURLScheme: CanvasAddress.scheme
        )
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
        let key = "\(theme.rawValue)\u{0}\(generation)\u{0}\(path.value)"
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
        guard let address = CanvasAddress.url(for: path) else { return }
        webView.load(URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData))
    }
}

// MARK: - Shared coordinator

/// Navigation policy for both artifact web views, plus the annotation bridge's plumbing —
/// and nothing but plumbing. What the page sent is validated by `CanvasAnnotation.decode`,
/// and *who sent it* by `CanvasAddress.accepts`; both are pure and testable, where a
/// `WKScriptMessage` is not.
///
/// Local-only enforcement lives here: any navigation that is not this artifact's own
/// `helm-canvas://` origin is cancelled — a link in a document or an .html page's remote
/// reference goes nowhere.
@MainActor
final class CanvasFileCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    /// The world helm's own script and the bridge share, and no page script can reach.
    ///
    /// `add(_:name:)` without a world registers into the **page content world**, where any
    /// script in the document — including one an artifact fetched, or an injected
    /// `<script>` — can post to the handler. Naming a world scopes both halves: helm's
    /// annotation script is injected `in:` it and the handler is registered
    /// `contentWorld:` it, so a page's own JS sees no `helmCanvas` at all.
    static let bridgeWorld = WKContentWorld.world(name: "helm-canvas-bridge")

    var loadedKey: String?
    /// The generated document the scheme handler should serve on the next request. Only
    /// the markdown canvas stages one; the .html canvas reads its artifact from disk.
    var stagedDocument: Data?

    /// Which canvas this coordinator belongs to. A message whose origin is not this host
    /// is not this canvas's message.
    private let host: String
    private let onAnnotation: (CanvasPageSelection) -> Void
    private lazy var proxy = WeakScriptMessageProxy(self)

    init(host: String, onAnnotation: @escaping (CanvasPageSelection) -> Void) {
        self.host = host
        self.onAnnotation = onAnnotation
    }

    func installBridge(on controller: WKUserContentController) {
        controller.add(
            proxy, contentWorld: CanvasFileCoordinator.bridgeWorld,
            name: CanvasBridgePolicy.handlerName)
        addAnnotationScript(to: controller)
    }

    func addAnnotationScript(to controller: WKUserContentController) {
        controller.addUserScript(
            WKUserScript(
                source: CanvasHTML.annotationScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: CanvasFileCoordinator.bridgeWorld
            )
        )
    }

    /// Called from `dismantleNSView`, and that is the only place it can work from.
    /// `add(_:contentWorld:name:)` retains the handler **strongly** and the controller is
    /// reachable from the webview, so relying on the handler's own `deinit` cannot work —
    /// the cycle is precisely what stops `deinit` firing. The weak proxy and this call are
    /// both needed; neither alone is reliable.
    func removeBridge(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(
            forName: CanvasBridgePolicy.handlerName, contentWorld: CanvasFileCoordinator.bridgeWorld
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        if let url, url.scheme == CanvasAddress.scheme || url.absoluteString == "about:blank" {
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
            let frame = message.frameInfo
            guard
                CanvasAddress.accepts(
                    isMainFrame: frame.isMainFrame,
                    originScheme: frame.securityOrigin.protocol,
                    originHost: frame.securityOrigin.host,
                    expectedHost: host)
            else { return }
            guard let report = CanvasPageSelection(message.body) else { return }
            onAnnotation(report)
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

/// Everything the annotation bridge can say: there is a selection to comment on, or there
/// is not one any more — a click on the page that left nothing selected.
///
/// **A body that decodes to neither is dropped, not treated as `.cleared`.** A dismissal is
/// something the operator did; a payload helm does not recognise is a bug or an impostor,
/// and letting the second stand in for the first would make a malformed message close a
/// field the operator was typing in. A selection must carry text for the same reason in
/// reverse — a report with none would put an empty comment field over the page.
enum CanvasPageSelection {
    case selected(CanvasSelection)
    case cleared

    init?(_ body: Any) {
        guard let payload = body as? [String: Any] else { return nil }
        if payload["cleared"] as? Bool == true {
            self = .cleared
        } else if let text = payload["text"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let selection = CanvasSelection(payload)
        {
            self = .selected(selection)
        } else {
            return nil
        }
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
