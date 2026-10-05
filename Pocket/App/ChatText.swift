import PocketKit
import SwiftUI
import UIKit

/// A reply's markdown drawn for `MarkdownView`: its runs of text blocks each as one attributed
/// string for a `UITextView` (`SelectableText`), so a selection runs across them, and each table
/// apart, as a grid of cells. Everything is in the one monospaced face.
@MainActor
enum ChatText {
    /// One part of a reply: blocks drawn as one text, or a table.
    enum Segment {
        case text(NSAttributedString)
        /// Each row's cells, drawn; the header row first when `header`.
        case table(rows: [[NSAttributedString]], header: Bool)
    }

    /// `text`'s segments, kept while the text and its links hold: a chat draws a reply on every
    /// update, and the text views know their text by identity.
    static func segments(
        _ text: String, font: UIFont, color: UIColor, links: StoreLinks = StoreLinks()
    ) -> [Segment] {
        if let kept = drawn[text], kept.links == links, kept.font == font { return kept.segments }
        if drawn.count >= 400 { drawn.removeAll() }
        let segments = draw(text, font: font, color: color, links: links)
        drawn[text] = (links, font, segments)
        return segments
    }

    private static var drawn: [String: (links: StoreLinks, font: UIFont, segments: [Segment])] =
        [:]

    private static func draw(
        _ text: String, font: UIFont, color: UIColor, links: StoreLinks
    ) -> [Segment] {
        let blocks = ChatMarkdown.blocks(text).map { linked($0, with: links) }
        var segments: [Segment] = []
        var run = NSMutableAttributedString()
        func closeRun() {
            if run.length > 0 { segments.append(.text(run)) }
            run = NSMutableAttributedString()
        }
        for (at, block) in blocks.enumerated() {
            if case let .table(rows, header) = block.kind {
                closeRun()
                let bold = bolder(font)
                segments.append(
                    .table(
                        rows: rows.enumerated().map { index, row in
                            row.map {
                                inline($0, font: header && index == 0 ? bold : font, color: color)
                            }
                        }, header: header))
                continue
            }
            if run.length > 0 { run.append(NSAttributedString(string: "\n")) }
            // Items of one list sit close; every other block has room above the next.
            let next = blocks.indices.contains(at + 1) ? blocks[at + 1].kind : nil
            run.append(draw(block, font: font, color: color, spacing: spacing(block.kind, next)))
        }
        closeRun()
        return segments
    }

    /// The space under a block: none at the end of a run of text (the segments' own spacing
    /// follows), a little between items of one list, and room between any other two blocks.
    private static func spacing(_ kind: MarkdownBlock.Kind, _ next: MarkdownBlock.Kind?) -> CGFloat
    {
        guard let next, !isTable(next) else { return 0 }
        return isItem(kind) && isItem(next) ? 3 : 8
    }

    private static func isItem(_ kind: MarkdownBlock.Kind) -> Bool {
        if case .item = kind { true } else { false }
    }

    private static func isTable(_ kind: MarkdownBlock.Kind) -> Bool {
        if case .table = kind { true } else { false }
    }

    private static func linked(_ block: MarkdownBlock, with links: StoreLinks) -> MarkdownBlock {
        var block = block
        block.text = links.linking(block.text)
        if case let .table(rows, header) = block.kind {
            block.kind = .table(rows: rows.map { $0.map(links.linking) }, header: header)
        }
        return block
    }

    private static func draw(
        _ block: MarkdownBlock, font: UIFont, color: UIColor, spacing: CGFloat
    )
        -> NSAttributedString
    {
        func paragraph(
            _ text: NSAttributedString, first: CGFloat = 0, rest: CGFloat = 0, next: CGFloat? = nil
        ) -> NSAttributedString {
            ChatText.paragraph(text, first: first, rest: rest, next: next, spacing: spacing)
        }
        let space = " ".size(withAttributes: [.font: font]).width
        switch block.kind {
        case .paragraph:
            return paragraph(inline(block.text, font: font, color: color))
        case let .heading(level):
            let size = font.pointSize + (level <= 2 ? 2 : 0)
            let heading = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
            return paragraph(inline(block.text, font: heading, color: color))
        case let .item(depth, marker):
            // The marker hangs: wrapped lines start under the text, not under the marker.
            let indent = CGFloat(depth - 1) * 2 * space
            let line = NSMutableAttributedString(
                string: marker + " ",
                attributes: [.font: font, .foregroundColor: UIColor(Palette.dim)])
            line.append(inline(block.text, font: font, color: color))
            let text = indent + CGFloat(marker.count + 1) * space
            return paragraph(line, first: indent, rest: text)
        case .code:
            return paragraph(
                code(block.text, font: font, color: color))
        case .quote:
            // The bar on every line of it; a wrapped line starts under the text.
            let bar = NSAttributedString(
                string: "│ ", attributes: [.font: font, .foregroundColor: UIColor(Palette.faint)])
            let line = inline(block.text, font: font, color: UIColor(Palette.dim))
            for at in line.string.indices(of: "\n").reversed() {
                line.insert(bar, at: at + 1)
            }
            line.insert(bar, at: 0)
            return paragraph(line, first: 0, rest: 2 * space, next: 0)
        case .table:
            preconditionFailure("a table is drawn apart, as a grid (segments)")
        case .rule:
            return paragraph(
                NSAttributedString(
                    string: String(repeating: "─", count: 12),
                    attributes: [.font: font, .foregroundColor: UIColor(Palette.dim)]))
        }
    }

    private static func code(
        _ text: AttributedString, font: UIFont, color: UIColor
    ) -> NSAttributedString {
        let out = inline(text, font: font, color: color)
        out.addAttribute(
            .backgroundColor, value: UIColor(Palette.sheet),
            range: NSRange(location: 0, length: out.length))
        return out
    }

    /// `text` in `font` and `color`, with its inline markdown: bold, italic, code in the reply
    /// colour, links kept.
    static func inline(
        _ text: AttributedString, font: UIFont, color: UIColor
    )
        -> NSMutableAttributedString
    {
        let out = NSMutableAttributedString(text)
        out.addAttributes(
            [.font: font, .foregroundColor: color], range: NSRange(location: 0, length: out.length))
        for run in text.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let range = NSRange(run.range, in: text)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if !traits.isEmpty,
                let descriptor = font.fontDescriptor.withSymbolicTraits(
                    font.fontDescriptor.symbolicTraits.union(traits))
            {
                out.addAttribute(
                    .font, value: UIFont(descriptor: descriptor, size: 0), range: range)
            }
            if intent.contains(.code) {
                out.addAttribute(.foregroundColor, value: UIColor(Palette.finished), range: range)
            }
        }
        return out
    }

    private static func bolder(_ font: UIFont) -> UIFont {
        font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) }
            ?? font
    }

    /// A block's paragraphs, one per line of it: the first line indented `first`, each later one
    /// `next` (`rest` when nil), a wrapped line `rest`, and `spacing` under the last only.
    private static func paragraph(
        _ text: NSAttributedString, first: CGFloat, rest: CGFloat, next: CGFloat?,
        spacing: CGFloat
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let string = out.string as NSString
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byParagraphs, .substringNotRequired]
        ) { _, range, enclosing, _ in
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = range.location == 0 ? first : next ?? rest
            style.headIndent = rest
            style.paragraphSpacing = NSMaxRange(enclosing) >= string.length ? spacing : 0
            out.addAttribute(.paragraphStyle, value: style, range: enclosing)
        }
        return out
    }
}

extension String {
    /// The UTF-16 offsets of `character`, as `NSAttributedString` counts.
    fileprivate func indices(of character: Character) -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        for c in self {
            if c == character { offsets.append(offset) }
            offset += c.utf16.count
        }
        return offsets
    }
}
