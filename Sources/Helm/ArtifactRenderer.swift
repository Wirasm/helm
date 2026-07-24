import Foundation
import SwiftUI

/// Pure text → renderable-segment routing for the artifact pane. No I/O, no
/// AppKit views — fully exercisable from `swift test` without a GUI.
///
/// Markdown prose is NOT flattened to an `AttributedString` here: block-level
/// typography (headings, code fills, hanging list indents, paragraph spacing)
/// needs real views, so markdown segments carry their raw source and the pane
/// renders them with `MarkdownText` under `MarkdownTheme.document`. Only plain
/// (non-markdown) text is pre-styled into an `AttributedString`.
enum ArtifactRenderer {
    /// Non-markdown text files render in this — verbatim, monospaced.
    static let monoFont = Font.system(size: 12, design: .monospaced)

    /// Extensions rendered as formatted markdown; everything else is plain
    /// monospaced text.
    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased())
    }

    /// Extensions rendered in a full-pane WKWebView instead of native text
    /// (the artifact pane's escape hatch — see ArtifactWebViews.swift).
    static func isHTML(_ url: URL) -> Bool {
        ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    // MARK: Segments (markdown interleaved with mermaid islands)

    /// One displayable chunk of an artifact: pre-styled plain text, raw
    /// markdown prose (the pane renders it with the document theme), or a
    /// mermaid diagram rendered by an inline web island.
    enum RenderedSegment {
        case text(AttributedString)
        case markdown(String)
        case mermaid(String)
    }

    /// The pane's real entry point: markdown files split at ```mermaid fences
    /// into interleaved prose/diagram segments; everything else stays a single
    /// monospaced text segment.
    static func renderSegments(_ raw: String, from url: URL) -> [RenderedSegment] {
        guard isMarkdown(url) else { return [.text(renderPlainText(raw))] }
        return ArtifactSegment.split(raw).map { segment in
            switch segment {
            case let .markdown(markdown): .markdown(markdown)
            case let .mermaid(source): .mermaid(source)
            }
        }
    }

    /// Non-markdown text files: verbatim, monospaced.
    static func renderPlainText(_ raw: String) -> AttributedString {
        var text = AttributedString(raw)
        text.font = monoFont
        return text
    }
}
