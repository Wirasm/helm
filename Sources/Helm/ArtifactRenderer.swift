import Foundation
import SwiftUI

/// Pure text → `AttributedString` rendering for the artifact pane. No I/O, no
/// AppKit views — fully exercisable from `swift test` without a GUI.
///
/// Markdown goes through Foundation's parser (`AttributedString(markdown:)`
/// with `.full` block interpretation) and is then restyled: the parser only
/// attaches `PresentationIntent` metadata — SwiftUI's `Text` renders inline
/// intents but ignores block intents entirely (headings would come out
/// body-sized, blocks would run together on one line). So we walk the runs,
/// re-insert block breaks, prefix list items, and map intents to fonts.
enum ArtifactRenderer {
    // MARK: Typography (single source of truth for the pane + tests)

    static let bodyFont = Font.system(size: 13)
    static let monoFont = Font.system(size: 12, design: .monospaced)

    static func headingFont(level: Int) -> Font {
        switch level {
        case 1: .system(size: 24, weight: .bold)
        case 2: .system(size: 19, weight: .semibold)
        case 3: .system(size: 16, weight: .semibold)
        default: .system(size: 13, weight: .semibold)
        }
    }

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

    static func render(_ raw: String, from url: URL) -> AttributedString {
        isMarkdown(url) ? renderMarkdown(raw) : renderPlainText(raw)
    }

    // MARK: Segments (markdown interleaved with mermaid islands)

    /// One displayable chunk of an artifact: native text, or a mermaid diagram
    /// rendered by an inline web island.
    enum RenderedSegment {
        case text(AttributedString)
        case mermaid(String)
    }

    /// The pane's real entry point: markdown files split at ```mermaid fences
    /// into interleaved text/diagram segments; everything else stays a single
    /// text segment — non-mermaid files render exactly as before.
    static func renderSegments(_ raw: String, from url: URL) -> [RenderedSegment] {
        guard isMarkdown(url) else { return [.text(renderPlainText(raw))] }
        return ArtifactSegment.split(raw).map { segment in
            switch segment {
            case let .markdown(markdown): .text(renderMarkdown(markdown))
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

    static func renderMarkdown(_ raw: String) -> AttributedString {
        guard let parsed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            // Unparseable markdown still has to be readable — fall back to plain.
            return renderPlainText(raw)
        }

        var output = AttributedString()
        // Traits of the previously emitted run: blocks are only distinguishable
        // by their intent's identity (the parser strips the newlines between
        // them), so a change of identity means "insert a block break here".
        var previousBlockID: Int?
        var previousWasListItem = false

        for run in parsed.runs {
            var fragment = AttributedString(parsed[run.range])
            let block = blockTraits(of: run.presentationIntent)

            if let previous = previousBlockID, previous != block.id {
                // Consecutive list items → single newline; otherwise a blank line.
                let tight = block.isListItem && previousWasListItem
                output += AttributedString(tight ? "\n" : "\n\n")
            }

            if previousBlockID != block.id, let prefix = block.listPrefix {
                var bullet = AttributedString(prefix)
                bullet.font = bodyFont
                output += bullet
            }

            fragment.font = font(for: block, inlineIntent: run.inlinePresentationIntent)
            if block.isBlockQuote {
                fragment.foregroundColor = .secondary
            }
            output += fragment
            previousBlockID = block.id
            previousWasListItem = block.isListItem
        }
        return output
    }

    // MARK: Block classification

    private struct BlockTraits {
        var id: Int?
        var headingLevel: Int?
        var isCodeBlock = false
        var isBlockQuote = false
        var isListItem = false
        var listPrefix: String?
    }

    private static func blockTraits(of intent: PresentationIntent?) -> BlockTraits {
        var traits = BlockTraits()
        guard let intent else { return traits }
        // Components run innermost-first; the innermost identity is the block ID
        // (distinct per paragraph/heading/code block/list item).
        traits.id = intent.components.first?.identity
        for component in intent.components {
            switch component.kind {
            case let .header(level):
                traits.headingLevel = level
            case .codeBlock:
                traits.isCodeBlock = true
            case .blockQuote:
                traits.isBlockQuote = true
            case let .listItem(ordinal):
                traits.isListItem = true
                traits.listPrefix = "•  "
                if intent.components.contains(where: { $0.kind == .orderedList }) {
                    traits.listPrefix = "\(ordinal). "
                }
            default:
                break
            }
        }
        return traits
    }

    private static func font(
        for block: BlockTraits,
        inlineIntent: InlinePresentationIntent?
    ) -> Font {
        if let level = block.headingLevel {
            return headingFont(level: level)
        }
        if block.isCodeBlock || inlineIntent?.contains(.code) == true {
            return monoFont
        }
        return bodyFont
    }
}
