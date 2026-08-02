import Foundation

/// Which canvases carry the annotation bridge.
///
/// **Never the URL source.** #33's second constraint: a message handler on a webview that
/// loads arbitrary websites lets any page post into helm. This policy is one half of that
/// guarantee; the structural half is that the URL source builds its own
/// `WKWebViewConfiguration` in a different file (`URLCanvasViews.swift`) and never touches
/// the annotated one.
///
/// Pure on purpose, exactly like `CanvasURLPolicy` and `TerminalURLPolicy`: a
/// `WKScriptMessage` cannot be built in a test, so the decision lives here where
/// `swift test` reaches it and the coordinator is left with nothing but the plumbing.
enum CanvasBridgePolicy {
    /// The handler's name, and therefore `window.webkit.messageHandlers.helmCanvas`. On a
    /// canvas without the bridge this name is simply undefined, which is the check the
    /// manual pass runs against a URL canvas.
    static let handlerName = "helmCanvas"

    static func installsBridge(for source: CanvasSource) -> Bool {
        if case .file = source { true } else { false }
    }
}
