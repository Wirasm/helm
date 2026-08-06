import AppKit
import SwiftUI

/// Block-level markdown. Agent output IS markdown — headings,
/// lists, fences — but `AttributedString(markdown:)` alone either flattens blocks
/// (full parse joins everything into one paragraph-soup string) or keeps the raw
/// `##`/``` markers (inline-only parse). So: split the text into blocks ourselves,
/// then inline-parse each block's text. No external dependencies, plain text on
/// any parse failure.
/// **The surface it was kept for arrived: the sidecar drawer (#198).** This was written
/// for the conversation view that left with the kild layer, and retained on the argument
/// that the next thing to need it would render many small blocks of prose rather than one
/// document — where a WKWebView would be absurd. That is exactly the drawer: a panel over
/// the canvas showing the notes written beside it, inside a pane whose main content is
/// already a webview.
///
/// The canvas document itself still does not use it. A whole artifact renders through
/// marked.js, because it has to be the same rendering an agent validates with a headless
/// browser (`CanvasFileViews`); the drawer renders helm's own sidecar, which nothing else
/// looks at.
enum PostMarkdown {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// One list item; `marker` is "•" for unordered, "1." style for ordered.
        case listItem(marker: String, text: String)
        case code(language: String?, code: String)
    }

    /// Split post text into renderable blocks: fenced code, headings, list items,
    /// and blank-line-separated paragraphs (inner newlines preserved). An
    /// unterminated fence still yields a code block — agents get cut off mid-report.
    static func blocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String]?
        var codeLanguage: String?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if codeLines != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(
                        .code(language: codeLanguage, code: codeLines!.joined(separator: "\n")))
                    codeLines = nil
                    codeLanguage = nil
                } else {
                    codeLines!.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                codeLines = []
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if let item = parseListItem(trimmed) {
                flushParagraph()
                blocks.append(item)
                continue
            }

            paragraph.append(line)
        }

        if let codeLines {
            blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    /// `#`–`######` followed by a space and text.
    private static func parseHeading(_ line: String) -> Block? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    /// `- ` / `* ` / `+ ` (→ "•") or `1. ` / `1) ` (marker kept). Nesting flattens.
    private static func parseListItem(_ line: String) -> Block? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            let text = line.dropFirst(bullet.count).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return .listItem(marker: "•", text: text)
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard let punct = afterDigits.first, punct == "." || punct == ")" else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .listItem(marker: "\(digits).", text: text)
    }
}

/// Renders markdown text as blocks: structure from `PostMarkdown.blocks`,
/// inline bold/italic/code per block via AttributedString, every font and
/// spacing decision from a `MarkdownTheme` profile. Body text is primary ink —
/// long agent reports and documents must be comfortably readable.
struct MarkdownText: View {
    let text: String
    var theme: MarkdownTheme = .chat

    var body: some View {
        let blocks = PostMarkdown.blocks(from: text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(
                        .top,
                        theme.spacing(above: block, after: index > 0 ? blocks[index - 1] : nil)
                    )
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: PostMarkdown.Block) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(theme.headingFont(level: level))
        case let .paragraph(text):
            inline(text)
                .font(theme.bodyFont)
                .lineSpacing(theme.lineSpacing)
        case let .listItem(marker, text):
            // Fixed marker column → wrapped lines hang cleanly under the text,
            // not under the bullet.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(marker)
                    .font(theme.bodyFont)
                    .foregroundStyle(Color.textMuted)
                    .frame(minWidth: theme.listMarkerWidth, alignment: .leading)
                inline(text)
                    .font(theme.bodyFont)
                    .lineSpacing(theme.lineSpacing)
            }
        case let .code(_, code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(theme.codeBlockFont)
                    .lineSpacing(2)
                    .padding(theme.codeBlockInset)
            }
            .background(
                Color.surfaceRaised,
                in: RoundedRectangle(cornerRadius: theme.codeBlockCornerRadius)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Inline markdown (bold, italic, `code`) for one block's text; inline code gets
    /// the theme's mono font + a subtle fill. Parse failure falls back to the
    /// literal text.
    private func inline(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return Text(source)
        }
        let codeRanges = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            attributed[range].font = theme.inlineCodeFont
            attributed[range].backgroundColor = Color.surfaceRaised
        }
        return Text(attributed)
    }
}
