import Foundation

/// Which files helm can render, decided by extension alone.
///
/// Lives in `Shared/` because three verticals ask the same question and none of them
/// owns it: the artifact browser asks it to decide what to list, the terminal asks it
/// to decide whether a ⌘-clicked link opens in helm or goes to the system, and the
/// canvas asks it to pick a renderer. It used to sit on `ArtifactHTML`, which meant
/// two verticals depended on an HTML *generation* module to answer a *routing*
/// question.
///
/// Extension-only on purpose: the callers that matter must answer before opening the
/// file — the terminal decides where a click goes without reading anything, and the
/// browser classifies a whole store per popover open. Content sniffing would make
/// both of those do I/O they currently avoid.
enum RenderableFile {
    /// Rendered as a formatted markdown document.
    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased())
    }

    /// Rendered in a full-pane WKWebView from its own URL.
    static func isHTML(_ url: URL) -> Bool {
        ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    /// True when helm has a renderer for this file at all — the question the
    /// terminal and the browser actually ask.
    static func isRenderable(_ url: URL) -> Bool {
        isMarkdown(url) || isHTML(url)
    }
}
