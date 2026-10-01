import WebKit
import XCTest

@testable import Helm

@MainActor
final class CanvasSourceAnchorPage: NSObject, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var messages: [[String: Any]] = []
    private var loaded = false

    init(markdown: String) throws {
        super.init()
        let controller = WKUserContentController()
        controller.add(
            self, contentWorld: CanvasFileCoordinator.bridgeWorld, name: "helmCanvas")
        controller.add(self, name: "ready")
        controller.addUserScript(
            WKUserScript(
                source: try XCTUnwrap(CanvasHTML.vendoredMarked()),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        if markdown.contains("```mermaid") {
            controller.addUserScript(
                WKUserScript(
                    source: try XCTUnwrap(CanvasHTML.vendoredMermaid()),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true))
        }
        controller.addUserScript(
            WKUserScript(
                source: CanvasHTML.annotationScript(), injectionTime: .atDocumentEnd,
                forMainFrameOnly: true, in: CanvasFileCoordinator.bridgeWorld))
        controller.addUserScript(
            WKUserScript(
                source: "window.webkit.messageHandlers.ready.postMessage('ready');",
                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController = controller
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        webView.loadHTMLString(
            CanvasHTML.documentPage(markdown: markdown, theme: .light), baseURL: nil)
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        if message.name == "ready" { loaded = true }
        if let body = message.body as? [String: Any] { messages.append(body) }
    }

    func select(_ selectors: [String]) async throws -> [[String: Any]] {
        try await wait { self.loaded }
        for selector in selectors {
            let count = messages.count
            webView.evaluateJavaScript(
                """
                (function() {
                  \(CanvasHTML.setMarkTool(.text, theme: .light))
                  var deadline = Date.now() + 10000;
                  function markWhenReady() {
                  var node = document.querySelector(\(CanvasHTML.jsString(selector)));
                  if (!node) {
                    if (Date.now() < deadline) { setTimeout(markWhenReady, 10); }
                    return;
                  }
                  var range = document.createRange(); range.selectNodeContents(node);
                  var selection = document.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                  document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
                  }
                  markWhenReady();
                })();
                """, in: nil, in: CanvasFileCoordinator.bridgeWorld, completionHandler: { _ in }
            )
            try await wait { self.messages.count > count }
        }
        return messages
    }

    /// A second visible copy makes quote fallback ambiguous, so an ID test can only pass
    /// through identifier lookup. The echo has no id and cannot match the captured source id.
    func repeatLabel(_ text: String) async throws {
        let echoed: String = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                "var echo = document.createElement('p'); echo.textContent = text; document.body.appendChild(echo); return echo.textContent;",
                arguments: ["text": text], in: nil, in: CanvasFileCoordinator.bridgeWorld
            ) { result in
                continuation.resume(with: result.map { ($0 as? String) ?? "" })
            }
        }
        XCTAssertEqual(echoed, text)
    }

    /// Exercise the real sidecar parser and Swift-to-page hover bridge after capture.
    func hover(_ annotation: CanvasAnnotation) async throws -> Bool {
        let note = try XCTUnwrap(
            CanvasNotes.entries(in: CanvasNotes.entry(annotation, at: Date())).first)
        let hover = CanvasNoteHover()
        hover.webView = webView
        hover.hover(note, entered: true)
        defer { hover.clear() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if hover.status[note.id] != nil { return false }
            let painted: String = try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript(
                    "String(!!window.CSS && CSS.highlights.has('helm-note'));", in: nil,
                    in: CanvasFileCoordinator.bridgeWorld
                ) { result in
                    continuation.resume(with: result.map { ($0 as? String) ?? "false" })
                }
            }
            if painted == "true" { return true }
            // Polling lets an interval elapse; only a highlight or a reported refusal decides.
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Hover neither painted nor reported a refusal within its deadline")
        return false
    }

    // Poll an observable with a deadline; elapsed time alone never passes an assertion.
    private func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !ready() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ready(), "WebKit did not report within the deadline")
        if !ready() { throw NSError(domain: "CanvasSourceAnchorTests", code: 1) }
    }

    func close() {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }
}
