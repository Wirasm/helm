import SwiftUI
import WebKit

// SECURITY: this is the canvas's REMOTE source, and it is a separate file from
// ArtifactWebViews.swift on purpose. That file's coordinator cancels every
// navigation that is not local, which is the right posture for an artifact and
// the wrong one for a dev server — so this source brings its own coordinator
// rather than relaxing that one. What keeps this half honest is
// `CanvasURLPolicy`: http and https, nothing else, so a page cannot redirect the
// canvas into an app scheme. Cookies live in the shared jar
// (`WKWebsiteDataStore.default()`) so a site that needs a login needs it once.

// MARK: - The page

/// A URL as a full-pane WKWebView. Reloads only when the (url, generation) pair
/// actually changes — `generation` is the model's load counter, so re-submitting
/// the address you are already on still retries.
struct URLCanvasView: NSViewRepresentable {
    @ObservedObject var model: ArtifactPaneModel
    let url: URL
    let generation: Int

    func makeCoordinator() -> URLCanvasCoordinator {
        URLCanvasCoordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The whole "no login story" (#31): the default jar persists across
        // launches, so it is log in once per site, ever — never an empty jar.
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        load(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(webView, coordinator: context.coordinator)
    }

    private func load(_ webView: WKWebView, coordinator: URLCanvasCoordinator) {
        guard coordinator.loadedURL != url || coordinator.loadedGeneration != generation else {
            return
        }
        coordinator.loadedURL = url
        coordinator.loadedGeneration = generation
        webView.load(URLRequest(url: url))
    }
}

// MARK: - The second navigation coordinator

/// Navigation policy for the URL source — the counterpart to
/// `ArtifactWebCoordinator`, which this deliberately does not touch.
///
/// It reports back to the model rather than swallowing anything: a page that
/// fails to load says why (WKWebView's own answer is a blank white pane), and a
/// navigation this policy refuses says so too, so a click that goes nowhere is
/// never silent.
@MainActor
final class URLCanvasCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// What the web view is already showing. Set both when helm drives it and
    /// when the page navigates itself, so reporting a link-click to the model
    /// does not bounce back as a fresh load.
    var loadedURL: URL?
    var loadedGeneration = -1

    private let model: ArtifactPaneModel

    init(model: ArtifactPaneModel) {
        self.model = model
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // Subframe loads are the page's own business — its iframes, a data: URL
        // for a font. The policy is about where the *canvas* goes, which is the
        // main frame (and a nil frame, which is a target=_blank about to ask for
        // a window).
        guard navigationAction.targetFrame?.isMainFrame ?? true else {
            decisionHandler(.allow)
            return
        }
        let url = navigationAction.request.url
        guard CanvasURLPolicy.allows(url) else {
            decisionHandler(.cancel)
            model.pageDidFail(
                "The canvas follows http and https only — did not open "
                    + (url?.absoluteString ?? "an empty link"))
            return
        }
        decisionHandler(.allow)
    }

    /// A target=_blank link navigates this pane instead of opening nothing,
    /// which is what returning nil alone would do. Single pane: N canvases are
    /// position 5, and a link that silently does nothing is worse than either.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, CanvasURLPolicy.allows(navigationAction.request.url)
        {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        loadedURL = url
        model.pageDidNavigate(to: url)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        report(error)
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        report(error)
    }

    /// Two codes are helm's own doing and would read as WebKit blaming the page:
    /// `NSURLErrorCancelled` is a navigation superseded by the next one, and
    /// `WebKitErrorDomain` 102 ("frame load interrupted") is how a `.cancel`
    /// decision comes back — which `decidePolicyFor` has already explained in
    /// the operator's terms. Everything else is real and is shown.
    private func report(_ error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        model.pageDidFail(error.localizedDescription)
    }
}

// MARK: - The address bar

/// The URL source's header: the address, a reload, a close. The file source keeps
/// its own header — a filename and reveal-in-Finder mean nothing here.
struct CanvasAddressBar: View {
    @ObservedObject var model: ArtifactPaneModel
    let page: ArtifactPaneModel.Page

    /// The half-typed address is the field's business, not the model's: the model
    /// holds only what was committed, so SwiftUI cannot navigate on a keystroke.
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            TextField("localhost:3000", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit { model.submitAddress(typed) }
            Button {
                model.reloadPage()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(page.url == nil)
            .help("Reload")
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close canvas")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear {
            typed = page.address
            // Opened with nothing loaded — that is ⌘L on a closed canvas, and the
            // only thing to do next is type.
            focused = page.url == nil
        }
        .onChange(of: page.address) { _, address in typed = address }
        // ⌘L on a canvas that is already showing a page means "edit this address".
        // The counter is what lets a second press re-focus a field that already exists.
        .onChange(of: model.addressFocus) { _, _ in focused = true }
    }
}
